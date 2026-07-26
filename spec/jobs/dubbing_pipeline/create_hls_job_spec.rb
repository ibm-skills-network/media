require "rails_helper"

RSpec.describe DubbingPipeline::CreateHlsJob, type: :job do
  # Build the task before stubbing File.* so the factory's attachment writes
  # can actually hit ActiveStorage's disk service
  let!(:task) do
    create(:dubbing_task, :with_audio, :with_dubbed_audio, :with_dubbed_video,
      segments: [
        { "start" => 0.0, "end" => 1.0, "text" => "Hi", "translated_text" => "Hola", "speaker" => "SPEAKER_0" }
      ],
      chapters: [ { "start" => 0.0, "title" => "Intro", "title_dubbed" => "Introducción" } ]
    )
  end

  before do
    stub_dubbing_workspace
    # ffprobe duration + every ffmpeg HLS pass all funnel through Open3.capture3
    allow(Open3).to receive(:capture3).and_return([ "10.0", "", double(success?: true) ])
    allow(FileUtils).to receive(:mkdir_p)
    allow(File).to receive(:write)
    allow(File).to receive(:open).and_yield(StringIO.new)
    allow(DubbingHlsUploader).to receive(:upload_dir).and_return("https://cos.example.com/bucket/dubbing/#{task.id}-#{task.playback_key}/hls/master.m3u8")
    allow(DubbingPipeline::CleanupJob).to receive(:perform_later)
  end

  describe "#perform" do
    it "sets hls_path to the uploaded master.m3u8 URL" do
      described_class.new.perform(task.id)
      expect(task.reload.hls_path).to end_with("master.m3u8")
    end

    it "hands off to CleanupJob" do
      described_class.new.perform(task.id)
      expect(DubbingPipeline::CleanupJob).to have_received(:perform_later).with(task.id)
    end

    it "uploads the HLS dir through DubbingHlsUploader" do
      described_class.new.perform(task.id)
      expect(DubbingHlsUploader).to have_received(:upload_dir).with(anything, an_instance_of(DubbingTask))
    end

    context "when the target language equals the source language" do
      it "raises before generating any HLS artifacts" do
        allow_any_instance_of(DubbingTask).to receive(:lang_code).and_return("en")
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /target language cannot equal source/)
      end
    end

    context "when ffprobe fails" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "ffprobe err", double(success?: false) ])
      end

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /ffprobe failed/)
      end
    end

    context "when the task is already in a terminal state" do
      it "returns without doing work" do
        task.update!(status: "failed")
        expect(Open3).not_to receive(:capture3)
        described_class.new.perform(task.id)
      end
    end
  end
end
