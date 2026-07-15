require "rails_helper"

RSpec.describe DubbingPipeline::CleanupJob, type: :job do
  let(:task) do
    create(:dubbing_task,
      :with_audio, :with_source_video, :with_vocals, :with_background,
      :with_dubbed_audio,
      hls_path: "https://cos.example.com/dubbing/1/hls/master.m3u8"
    )
  end

  describe "#perform" do
    before { allow(DubbingHlsUploader).to receive(:purge) }

    it "purges every intermediate attachment" do
      DubbingTask::INTERMEDIATE_ATTACHMENTS.each do |name|
        expect(task.public_send(name)).to be_attached
      end

      described_class.new.perform(task.id)

      task.reload
      DubbingTask::INTERMEDIATE_ATTACHMENTS.each do |name|
        expect(task.public_send(name)).not_to be_attached
      end
    end

    it "preserves the HLS prefix since it's the published deliverable" do
      expect(DubbingHlsUploader).not_to receive(:purge)
      described_class.new.perform(task.id)
    end

    it "preserves hls_path since the HLS bundle is the deliverable" do
      described_class.new.perform(task.id)
      expect(task.reload.hls_path).to end_with("master.m3u8")
    end

    it "marks the task successful" do
      described_class.new.perform(task.id)
      expect(task.reload.status).to eq("success")
    end

    context "when the task is already in a terminal state" do
      it "returns without purging" do
        task.update!(status: "failed")
        expect_any_instance_of(DubbingTask).not_to receive(:purge_pipeline_artifacts!)
        described_class.new.perform(task.id)
      end
    end
  end
end
