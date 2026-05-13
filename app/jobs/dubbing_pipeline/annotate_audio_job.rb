module DubbingPipeline
  class AnnotateAudioJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s)
      FileUtils.mkdir_p(output_dir)

      segments_in_path = output_dir.join("segments_in.json").to_s
      File.write(segments_in_path, task.segments.to_json)

      stdout, stderr, status = Open3.capture3(
        "python3", Rails.root.join("script/dubbing/annotate_audio.py").to_s,
        task.vocals_path,
        "--segments-file", segments_in_path,
        "--output-dir", output_dir.to_s
      )
      raise "Audio annotation failed: #{stderr}" unless status.success?

      task.update!(segments: JSON.parse(stdout))
      DubbingPipeline::IdentifyChaptersJob.perform_later(task_id)
    end
  end
end
