require "rails_helper"

RSpec.describe DubbingPipeline::SeparateAudioJob, type: :job do
  let(:task) { create(:dubbing_task, audio_path: "/tmp/dubbing/1/audio.wav") }

  describe "#perform" do
    context "when the Python script succeeds" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
        allow(DubbingPipeline::TranscribeJob).to receive(:perform_later)
      end

      it "updates vocals_path on the task" do
        described_class.new.perform(task.id)

        expect(task.reload.vocals_path).to include("vocals.wav")
      end

      it "updates background_path on the task" do
        described_class.new.perform(task.id)

        expect(task.reload.background_path).to include("background.wav")
      end

      it "enqueues TranscribeJob" do
        expect(DubbingPipeline::TranscribeJob).to receive(:perform_later).with(task.id)

        described_class.new.perform(task.id)
      end
    end

    context "when the Python script fails" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "Demucs error", double(success?: false) ])
      end

      it "raises an error" do
        expect {
          described_class.new.perform(task.id)
        }.to raise_error(RuntimeError, /Demucs failed/)
      end
    end
  end
end
