module DubbingPipeline
  class TranscribeJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)

      mp3_path = Rails.root.join("tmp", "dubbing", task_id.to_s, "vocals.mp3").to_s

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y",
        "-i", task.vocals_path,
        "-ar", "16000",
        "-ac", "1",
        "-b:a", "64k",
        mp3_path
      )
      raise "ffmpeg compression failed: #{stderr}" unless status.success?

      conn = Faraday.new do |f|
        f.request :multipart     # upload files
        f.request :url_encoded   # text
      end

      file = Faraday::UploadIO.new(mp3_path, "audio/mpeg")
      response = conn.post("https://api.openai.com/v1/audio/transcriptions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
        req.body = {
          file: file,
          model: "whisper-1",
          response_format: "verbose_json"
        }
      end

      segments = JSON.parse(response.body)["segments"].map do |seg|
        { start: seg["start"], end: seg["end"], text: seg["text"].strip }
      end

      task.update!(segments: segments)

      DubbingPipeline::DiarizeJob.perform_later(task_id)
    end
  end
end
