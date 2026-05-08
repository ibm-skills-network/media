module DubbingPipeline
  class CreateDubbedVideoJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s
      dubbed_video_path = File.join(output_dir, "dubbed.mp4")

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y",
        "-i", task.video_url,
        "-i", task.dubbed_audio_path,
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-map", "0:v:0",
        "-map", "1:a:0",
        dubbed_video_path
      )

      raise "ffmpeg failed: #{stderr}" unless status.success?

      task.update!(dubbed_video_path: dubbed_video_path)
      DubbingPipeline::CreateHlsJob.perform_later(task_id)
    end

  end
end
