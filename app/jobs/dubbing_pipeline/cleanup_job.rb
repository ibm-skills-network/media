module DubbingPipeline
  class CleanupJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg.dig("args", 0, "arguments", 0))
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      # Keep HLS so we can inspect what CreateHlsJob published
      task.purge_pipeline_artifacts!(include_hls: false)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      # Keep HLS, that's the deliverable the player streams from
      task.purge_pipeline_artifacts!(include_hls: false)
      task.update!(status: "success")
    end
  end
end
