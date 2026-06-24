module DubbingPipeline
  class SeparateAudioJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      DubbingWorkspace.with("#{task_id}-separate") do |ws|
        audio_path = ws.fetch(task.audio, "audio.wav")

        _stdout, stderr, status = Open3.capture3(
          "python3", Rails.root.join("script/dubbing/separate_audio.py").to_s,
          audio_path,
          "--output-dir", ws.dir
        )
        raise "Demucs failed: #{stderr}" unless status.success?

        ws.attach(task.vocals, "vocals.wav", content_type: "audio/wav")
        ws.attach(task.background, "background.wav", content_type: "audio/wav")
      end

      DubbingPipeline::TranscribeJob.perform_later(task_id)
    end
  end
end
