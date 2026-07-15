module DubbingPipeline
  class CleanupJob < BaseJob
    # Keep HLS on failure so we can inspect what CreateHlsJob published
    self.purge_hls_on_failure = false

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      task.purge_pipeline_artifacts!(include_hls: false)
      task.update!(status: "success")
    end
  end
end
