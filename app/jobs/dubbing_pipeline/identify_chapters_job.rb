module DubbingPipeline
  class IdentifyChaptersJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)

      transcript = task.segments.map do |seg|
        "[#{seg["start"].round(1)}s - #{seg["end"].round(1)}s] #{seg["text"]}"
      end.join("\n")

      conn = Faraday.new do |f|
        f.options.timeout = 120
        f.options.open_timeout = 10
      end
      response = conn.post("https://api.openai.com/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV["OPENAI_API_KEY"]}"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: "gpt-5-mini",
          response_format: { type: "json_object" },
          messages: [
            {
              role: "system",
              content: "You are a video editor. Given a transcript with timestamps, identify logical chapters/sections. " \
                       "Return a JSON object with a 'chapters' array of objects, each with 'start' (seconds as float), " \
                       "'title' (English), and 'title_dubbed' (#{task.language} translation)."
            },
            {
              role: "user",
              content: transcript
            }
          ]
        }.to_json
      end

      raise "GPT chapters failed: #{response.status} #{response.body}" unless response.success?

      parsed = JSON.parse(JSON.parse(response.body)["choices"][0]["message"]["content"])
      chapters = parsed["chapters"] || []
      task.update!(chapters: chapters)
      DubbingPipeline::TranslateJob.perform_later(task_id)
    end
  end
end
