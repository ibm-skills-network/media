module DubbingPipeline
  class IdentifyChaptersJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)

      transcript = task.segments.map do |seg|
        "[#{seg["start"].round(1)}s - #{seg["end"].round(1)}s] #{seg["text"]}"
      end.join("\n")

      response = Faraday.new.post("https://api.openai.com/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV["OPENAI_API_KEY"]}"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: "You are a video editor. Given a transcript with timestamps, identify logical chapters.
               Return a JSON array of objects with 'start' (float), 'title' (English),
               and 'title_dubbed' (#{task.language} translation). Return ONLY valid JSON."
            },
            {
              role: "user",
              content: transcript
            }
          ]
        }.to_json
      end
      chapters = JSON.parse(JSON.parse(response.body)["choices"][0]["message"]["content"])
      task.update!(chapters: chapters)
      DubbingPipeline::TranslateJob.perform_later(task_id)
    end
  end
end
