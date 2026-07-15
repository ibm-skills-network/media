require "rails_helper"

RSpec.describe DubbingPipeline::BaseJob, type: :job do
  describe ".sidekiq_retries_exhausted" do
    let(:task) { create(:dubbing_task, :with_audio, status: "processing") }
    let(:exception) { RuntimeError.new("boom") }

    # Shape of a dead ActiveJob-wrapped Sidekiq message: args carries the
    # ActiveJob serialization payload, not the perform arguments directly
    def death_msg(job_class, task_id)
      { "args" => [ { "job_class" => job_class.name, "arguments" => [ task_id ] } ] }
    end

    def exhaust(job_class, task_id)
      job_class.sidekiq_retries_exhausted_block.call(death_msg(job_class, task_id), exception)
    end

    it "marks the task failed and purges intermediates including HLS" do
      expect(DubbingHlsUploader).to receive(:purge).with(task)

      exhaust(DubbingPipeline::TranscribeJob, task.id)

      task.reload
      expect(task.status).to eq("failed")
      expect(task.error_message).to eq("boom")
      expect(task.audio).not_to be_attached
    end

    it "keeps the HLS prefix when CleanupJob dies" do
      expect(DubbingHlsUploader).not_to receive(:purge)

      exhaust(DubbingPipeline::CleanupJob, task.id)

      expect(task.reload.status).to eq("failed")
    end

    it "does nothing when the task no longer exists" do
      expect { exhaust(DubbingPipeline::TranscribeJob, -1) }.not_to raise_error
    end
  end
end
