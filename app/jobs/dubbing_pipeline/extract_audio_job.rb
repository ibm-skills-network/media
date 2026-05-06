module DubbingPipeline
  class ExtractAudioJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      task.processing!

      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s)
      FileUtils.mkdir_p(output_dir)

      audio_path = output_dir.join("audio.wav").to_s

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y",
        "-i", task.video_url,
        "-vn",
        "-acodec", "pcm_s16le",
        "-ar", "44100",
        "-ac", "2",
        audio_path
      )

      raise "ffmpeg failed: #{stderr}" unless status.success?

      task.update!(audio_path: audio_path)

      DubbingPipeline::SeparateAudioJob.perform_later(task_id)
    end
  end
end
