require "rails_helper"

RSpec.describe DubbingPipeline::CleanupJob, type: :job do
  let(:task) do
    create(:dubbing_task,
      audio_path:        "/tmp/dubbing/1/audio.wav",
      source_video_path: "/tmp/dubbing/1/source.mp4",
      vocals_path:       "/tmp/dubbing/1/vocals.wav",
      background_path:   "/tmp/dubbing/1/background.wav",
      dubbed_audio_path: "/tmp/dubbing/1/dubbed.mp3",
      dubbed_video_path: "/tmp/dubbing/1/dubbed.mp4",
      hls_path:          "/tmp/dubbing/1/hls/master.m3u8"
    )
  end

  before do
    allow(FileUtils).to receive(:rm_f)
    allow(Dir).to receive(:glob).and_return([ "/tmp/dubbing/1/tts_0.mp3", "/tmp/dubbing/1/tts_1.mp3" ])
  end

  describe "#perform" do
    it "deletes every intermediate artifact" do
      described_class::INTERMEDIATE_BASENAMES.each do |name|
        expect(FileUtils).to receive(:rm_f).with(have_attributes(to_s: end_with(name)))
      end
      described_class.new.perform(task.id)
    end

    it "deletes the per-segment tts clips" do
      expect(FileUtils).to receive(:rm_f).with("/tmp/dubbing/1/tts_0.mp3")
      expect(FileUtils).to receive(:rm_f).with("/tmp/dubbing/1/tts_1.mp3")
      described_class.new.perform(task.id)
    end

    it "nulls out the path columns that pointed to deleted files" do
      described_class.new.perform(task.id)
      task.reload
      expect(task.audio_path).to be_nil
      expect(task.source_video_path).to be_nil
      expect(task.vocals_path).to be_nil
      expect(task.background_path).to be_nil
      expect(task.dubbed_audio_path).to be_nil
      expect(task.dubbed_video_path).to be_nil
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
      it "returns without touching the filesystem" do
        task.update!(status: "failed")
        expect(FileUtils).not_to receive(:rm_f)
        described_class.new.perform(task.id)
      end
    end
  end
end
