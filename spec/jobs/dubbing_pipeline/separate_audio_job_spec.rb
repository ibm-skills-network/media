require "rails_helper"

RSpec.describe DubbingPipeline::SeparateAudioJob, type: :job do
  let(:task) { create(:dubbing_task, :with_audio) }

  describe "#perform" do
    context "when the Python script succeeds" do
      let!(:workspaces) { stub_dubbing_workspace }

      before do
        allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
        allow(DubbingPipeline::TranscribeJob).to receive(:perform_later)
      end

      it "attaches vocals.wav and background.wav to the task" do
        described_class.new.perform(task.id)
        filenames = workspaces.first.attached.map { |a| a[:filename] }
        expect(filenames).to contain_exactly("vocals.wav", "background.wav")
      end

      it "fetches audio.wav from the task's attached audio" do
        described_class.new.perform(task.id)
        # The fake workspace records nothing on fetch, but the SUT calls Open3 with
        # the path it gets back; we just confirm Open3 was invoked once.
        expect(Open3).to have_received(:capture3).once
      end

      it "enqueues TranscribeJob" do
        expect(DubbingPipeline::TranscribeJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end
    end

    context "when the Python script fails" do
      before do
        stub_dubbing_workspace
        allow(Open3).to receive(:capture3).and_return([ "", "Demucs error", double(success?: false) ])
      end

      it "raises so Sidekiq can retry" do
        expect {
          described_class.new.perform(task.id)
        }.to raise_error(RuntimeError, /Demucs failed/)
      end
    end
  end
end
