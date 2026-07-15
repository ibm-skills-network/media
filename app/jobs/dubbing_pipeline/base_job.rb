module DubbingPipeline
  # Shared failure handling for the pipeline: when Sidekiq exhausts retries,
  # mark the task failed and purge intermediates so failed runs don't leak PII.
  class BaseJob < ApplicationJob
    queue_as :low

    # CleanupJob flips this off so the published HLS output survives for inspection
    class_attribute :purge_hls_on_failure, default: true, instance_accessor: false

    sidekiq_retries_exhausted do |msg, exception|
      # Jobs here are ActiveJob-wrapped, so msg["args"].first is the ActiveJob
      # serialization payload; the task id lives in its "arguments"
      payload = msg["args"].first
      task = DubbingTask.find_by(id: payload["arguments"].first)
      next unless task

      task.update!(status: "failed", error_message: exception.message)
      include_hls = payload["job_class"].to_s.safe_constantize&.purge_hls_on_failure
      task.purge_pipeline_artifacts!(include_hls: include_hls != false)
    end
  end
end
