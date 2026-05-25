module DubbingPipeline
  class IdentifyChaptersJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

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
              content: <<~PROMPT
                You are a video editor segmenting a lecture or talk into chapters for a player's chapter menu.

                Aim for roughly one chapter every 2 to 4 minutes, with a minimum of 2 and a maximum of 12 chapters. Return an empty chapters array if the video is under 90 seconds.

                Each chapter should mark a real topical shift — a new concept, a new example, a new section of the argument. Do not insert chapters just to hit a count.

                Return a JSON object: { "chapters": [{ "start": <seconds float>, "title": "<English, max 60 chars>", "title_dubbed": "<#{task.language} translation, max 60 chars>" }] }
              PROMPT
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
      chapters = (parsed["chapters"] || []).map do |ch|
        ch.merge(
          "title" => ch["title"].to_s[0, 60],
          "title_dubbed" => ch["title_dubbed"].to_s[0, 60]
        )
      end
      task.update!(chapters: chapters)
      DubbingPipeline::TranslateJob.perform_later(task_id)
    end
  end
end
