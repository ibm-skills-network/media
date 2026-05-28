module DubbingPipeline
  class CreateDubbedVideoJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s
      dubbed_video_path = File.join(output_dir, "dubbed.mp4")

      # Mux the silent source video with the dubbed audio, video stream is copied as-is
      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y",
        "-i", task.source_video_path,
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
