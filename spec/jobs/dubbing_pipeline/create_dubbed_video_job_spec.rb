require "rails_helper"

RSpec.describe DubbingPipeline::CreateDubbedVideoJob, type: :job do
  let(:task) { create(:dubbing_task, :with_source_video, :with_dubbed_audio) }

  describe "#perform" do
    context "when ffmpeg succeeds" do
      let!(:workspaces) { stub_dubbing_workspace }

      before do
        allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
        allow(DubbingPipeline::CreateHlsJob).to receive(:perform_later)
      end

      it "attaches dubbed.mp4 to the task" do
        described_class.new.perform(task.id)
        filenames = workspaces.first.attached.map { |a| a[:filename] }
        expect(filenames).to eq([ "dubbed.mp4" ])
      end

      it "enqueues CreateHlsJob" do
        expect(DubbingPipeline::CreateHlsJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end

      it "uses the workspace source path, not the original video_url" do
        described_class.new.perform(task.id)
        expect(Open3).to have_received(:capture3) do |*args|
          expect(args).not_to include(task.video_url)
        end
      end
    end

    context "when ffmpeg fails" do
      before do
        stub_dubbing_workspace
        allow(Open3).to receive(:capture3).and_return([ "", "ffmpeg error", double(success?: false) ])
      end

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /ffmpeg failed/)
      end
    end

    context "when the task is already in a terminal state" do
      it "returns without shelling out" do
        task.update!(status: "failed")
        expect(Open3).not_to receive(:capture3)
        described_class.new.perform(task.id)
      end
    end
  end
end
