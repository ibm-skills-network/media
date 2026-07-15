require "rails_helper"

RSpec.describe DubbingPipeline::ExtractAudioJob, type: :job do
  let(:task) { create(:dubbing_task) }

  describe "#perform" do
    context "when ffmpeg succeeds" do
      let!(:workspaces) { stub_dubbing_workspace }

      before do
        allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
        allow(DubbingPipeline::SeparateAudioJob).to receive(:perform_later)
      end

      it "attaches audio.wav and source.mp4 to the task" do
        described_class.new.perform(task.id)

        filenames = workspaces.first.attached.map { |a| a[:filename] }
        expect(filenames).to contain_exactly("audio.wav", "source.mp4")
      end

      it "passes the ffmpeg protocol whitelist before -i" do
        described_class.new.perform(task.id)
        expect(Open3).to have_received(:capture3) do |*args|
          whitelist_idx = args.index("-protocol_whitelist")
          input_idx = args.index("-i")
          expect(whitelist_idx).to be_between(0, input_idx - 1)
          expect(args[whitelist_idx + 1]).to eq("http,https,tls,tcp")
        end
      end

      it "enqueues SeparateAudioJob" do
        expect(DubbingPipeline::SeparateAudioJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end

      it "marks the task as processing" do
        described_class.new.perform(task.id)
        expect(task.reload.status).to eq("processing")
      end
    end

    context "when ffmpeg fails" do
      before do
        stub_dubbing_workspace
        allow(Open3).to receive(:capture3).and_return([ "", "ffmpeg error", double(success?: false) ])
      end

      it "raises so Sidekiq can retry" do
        expect {
          described_class.new.perform(task.id)
        }.to raise_error(RuntimeError, /ffmpeg failed/)
      end
    end

    context "when the task is already in a terminal state" do
      it "returns without shelling out" do
        task.update!(status: "success")
        expect(Open3).not_to receive(:capture3)
        described_class.new.perform(task.id)
      end
    end
  end
end
