module DubbingPipeline
  class CreateDubbedVideoJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg.dig("args", 0, "arguments", 0))
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      DubbingWorkspace.with("#{task_id}-video") do |ws|
        source_path = ws.fetch(task.source_video, "source.mp4")
        dubbed_audio_path = ws.fetch(task.dubbed_audio, "dubbed.m4a")
        dubbed_video_path = ws.path("dubbed.mp4")

        # Mux silent source video with dubbed audio, video stream is copied as-is
        _stdout, stderr, status = Open3.capture3(
          "ffmpeg", "-y",
          "-i", source_path,
          "-i", dubbed_audio_path,
          "-c:v", "copy",
          "-c:a", "aac",
          "-b:a", "192k",
          "-map", "0:v:0",
          "-map", "1:a:0",
          dubbed_video_path
        )

        raise "ffmpeg failed: #{stderr}" unless status.success?

        ws.attach(task.dubbed_video, "dubbed.mp4", content_type: "video/mp4")
      end

      DubbingPipeline::CreateHlsJob.perform_later(task_id)
    end
  end
end
