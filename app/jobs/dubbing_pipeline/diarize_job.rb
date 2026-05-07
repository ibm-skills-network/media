module DubbingPipeline
  class DiarizeJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)

      stdout, stderr, status = Open3.capture3(
        "python3", Rails.root.join("script/dubbing/diarize.py").to_s,
        task.vocals_path,
        "--segments", task.segments.to_json,
        "--output-dir", Rails.root.join("tmp", "dubbing", task_id.to_s).to_s
      )
      raise "Diarization Failed: #{stderr}" unless status.success?

      task.update!(segments: JSON.parse(stdout))

      DubbingPipeline::IdentifyChaptersJob.perform_later(task_id)
    end
  end
end
