module DubbingPipeline
  class TranslateJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update(status: "failed", error_message: exception.message)
    end


    def perform(task_id)
      task = DubbingTask.find(task_id)

      full_text = task.segments.each_with_index.map do |seg, i|
        duration = (seg["end"] - seg["start"]).round(1)
        "[#{i} | #{duration}s] #{seg["text"]}"
      end.join("\n")

      response = Faraday.new.post("https://api.openai.com/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV["OPENAI_API_KEY"]}"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: "You are a professional dubbing translator. Translate this transcript to #{task.language}.
              Each line has [index|duration]. Return translations in the same format: [0|2.5s] Translation here.
              Return ONLY the translated lines, no extra text."
            },
            {
              role: "user",
              content: full_text
            }
          ]
        }.to_json
      end

      result = JSON.parse(response.body)["choices"][0]["message"]["content"]

      result.split("\n").each do |line|
        match = line.match(/\[(\d+)\|[\d.]+s\]\s*(.+)/)
        next unless match
        idx = match[1].to_i
        task.segments[idx]["translated_text"] = match[2].strip
      end

      task.save!
      DubbingPipeline::GenerateDubbedAudioJob.perform_later(task_id)
    end
  end
end
