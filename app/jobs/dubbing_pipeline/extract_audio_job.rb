module DubbingPipeline
  class ExtractAudioJob < BaseJob
    queue_as :gpu

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      task.processing!

      DubbingWorkspace.with("#{task_id}-extract") do |ws|
        audio_path = ws.path("audio.wav")
        source_video_path = ws.path("source.mp4")

        # -protocol_whitelist has to come before -i to apply to the input, blocks
        # file://, concat:, pipe: even when a redirect or playlist asks for them
        _stdout, stderr, status = Open3.capture3(
          "ffmpeg", "-y",
          "-protocol_whitelist", "http,https,tls,tcp",
          "-i", task.video_url,
          "-map", "0:a:0", "-acodec", "pcm_s16le", "-ar", "44100", "-ac", "2", audio_path,
          "-map", "0:v:0", "-c:v", "copy", "-an", source_video_path
        )

        raise "ffmpeg failed: #{stderr}" unless status.success?

        ws.attach(task.audio, "audio.wav", content_type: "audio/wav")
        ws.attach(task.source_video, "source.mp4", content_type: "video/mp4")
      end

      DubbingPipeline::SeparateAudioJob.perform_later(task_id)
    end
  end
end
