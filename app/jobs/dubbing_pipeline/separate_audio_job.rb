module DubbingPipeline
  class SeparateAudioJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s

      _stdout, stderr, status = Open3.capture3(
        "python3", Rails.root.join("script/dubbing/separate_audio.py").to_s,
        task.audio_path,
        "--output-dir", output_dir
      )
      raise "Demucs failed: #{stderr}" unless status.success?

      task.update!(
        vocals_path: File.join(output_dir, "vocals.wav"),
        background_path: File.join(output_dir, "background.wav")
      )

      DubbingPipeline::TranscribeJob.perform_later(task_id)
    end
  end
end
