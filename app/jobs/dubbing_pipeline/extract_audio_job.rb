module DubbingPipeline
  class ExtractAudioJob < ApplicationJob
    queue_as :gpu

    class InvalidSourceError < StandardError; end

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      task.processing!

      begin
        validate_source!(task.video_url)
      rescue InvalidSourceError => e
        task.update!(status: "failed", error_message: e.message)
        return
      end

      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s)
      FileUtils.mkdir_p(output_dir)

      audio_path = output_dir.join("audio.wav").to_s
      source_video_path = output_dir.join("source.mp4").to_s

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y",
        "-i", task.video_url,
        "-map", "0:a:0", "-acodec", "pcm_s16le", "-ar", "44100", "-ac", "2", audio_path,
        "-map", "0:v:0", "-c:v", "copy", "-an", source_video_path
      )

      raise "ffmpeg failed: #{stderr}" unless status.success?

      task.update!(audio_path: audio_path, source_video_path: source_video_path)
      DubbingPipeline::SeparateAudioJob.perform_later(task_id)
    end

    private

    def validate_source!(source)
      raise InvalidSourceError, "video_url is blank" if source.to_s.strip.empty?
      return if source.start_with?("http://", "https://")
      raise InvalidSourceError, "Local video not found: #{source}" unless File.exist?(source)
    end
  end
end
