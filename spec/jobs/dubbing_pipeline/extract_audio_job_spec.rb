require "rails_helper"

RSpec.describe DubbingPipeline::ExtractAudioJob, type: :job do
  let(:task) { create(:dubbing_task) }

  describe "#perform" do
    before do
      allow(FileUtils).to receive(:mkdir_p)
    end

    context "when ffmpeg succeeds" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
        allow(DubbingPipeline::SeparateAudioJob).to receive(:perform_later)
      end

      it "updates audio_path on the task" do
        described_class.new.perform(task.id)

        expect(task.reload.audio_path).to include("audio.wav")
      end

      it "enqueues SeparateAudioJob" do
        expect(DubbingPipeline::SeparateAudioJob).to receive(:perform_later).with(task.id)

        described_class.new.perform(task.id)
      end
    end

    context "when ffmpeg fails" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "ffmpeg error", double(success?: false) ])
      end

      it "raises an error" do
        expect {
          described_class.new.perform(task.id)
        }.to raise_error(RuntimeError, /ffmpeg failed/)
      end
    end
  end
end
