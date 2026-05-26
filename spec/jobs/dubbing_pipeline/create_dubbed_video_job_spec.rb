require "rails_helper"

RSpec.describe DubbingPipeline::CreateDubbedVideoJob, type: :job do
  let(:task) do
    create(:dubbing_task,
      source_video_path: "/tmp/dubbing/1/source.mp4",
      dubbed_audio_path: "/tmp/dubbing/1/dubbed.mp3"
    )
  end

  describe "#perform" do
    context "when ffmpeg succeeds" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
        allow(DubbingPipeline::CreateHlsJob).to receive(:perform_later)
      end

      it "sets dubbed_video_path on the task" do
        described_class.new.perform(task.id)
        expect(task.reload.dubbed_video_path).to end_with("dubbed.mp4")
      end

      it "enqueues CreateHlsJob" do
        expect(DubbingPipeline::CreateHlsJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end

      it "uses the locally-saved source video, not the original URL" do
        expect(Open3).to receive(:capture3) do |*args|
          expect(args).to include("/tmp/dubbing/1/source.mp4")
          expect(args).not_to include(task.video_url)
          [ "", "", double(success?: true) ]
        end
        described_class.new.perform(task.id)
      end
    end

    context "when ffmpeg fails" do
      before do
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
