require "rails_helper"
require "tmpdir"

RSpec.describe DubbingPipeline::GenerateDubbedAudioJob, type: :job do
  describe "#generate_tts_with_retranslation" do
    let(:job) { described_class.new }

    def call_with_slot(job, dir, slot_s: 4.0)
      job.send(:generate_tts_with_retranslation,
        text: "hola mundo esto es una prueba",
        original_text: "hello world this is a test",
        voice_id: "v1",
        voice_settings: { stability: 0.5 },
        slot_s: slot_s,
        target_lang: "Spanish",
        output_dir: dir,
        index: 0)
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    before do
      allow(job).to receive(:write_tts_clip) { |_text, _voice, path, _settings| File.binwrite(path, "x") }
    end

    it "accepts the first clip when the needed speedup is within COMFORT_SPEED" do
      allow(DubbingFfprobe).to receive(:duration_seconds).and_return(4.4) # 1.1x for a 4.0s slot
      expect(job).not_to receive(:retranslate_shorter)

      _path, text = call_with_slot(job, @dir)
      expect(text).to eq("hola mundo esto es una prueba")
    end

    it "retranslates when the speedup would be audible even though it is under MAX_SPEED" do
      allow(DubbingFfprobe).to receive(:duration_seconds).and_return(5.2, 3.0) # 1.3x, then fits
      expect(job).to receive(:retranslate_shorter)
        .with("hola mundo esto es una prueba", "hello world this is a test", 5.2, 4.0, "Spanish")
        .once.and_return("hola mundo")

      _path, text = call_with_slot(job, @dir)
      expect(text).to eq("hola mundo")
    end

    it "keeps the shortest attempt when nothing fits" do
      allow(DubbingFfprobe).to receive(:duration_seconds).and_return(8.0, 6.0, 7.0)
      allow(job).to receive(:retranslate_shorter).and_return("intento dos", "intento tres")

      path, text = call_with_slot(job, @dir)
      expect(text).to eq("intento dos")
      expect(File).to exist(path)
      expect(File).not_to exist(File.join(@dir, "tts_0_best.mp3"))
    end
  end

  describe "#merge_segments_for_tts" do
    let(:job) { described_class.new }

    it "merges short adjacent same-speaker segments under the gap threshold" do
      segments = [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno", "translated_text" => "uno", "speaker" => "S0" },
        { "start" => 1.2, "end" => 2.0, "text" => "Dos", "translated_text" => "dos", "speaker" => "S0" }
      ]
      merged = job.send(:merge_segments_for_tts, segments)
      expect(merged.length).to eq(1)
      expect(merged.first["translated_text"]).to eq("uno dos")
      expect(merged.first["end"]).to eq(2.0)
    end

    it "does not merge across speaker change" do
      segments = [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno", "translated_text" => "uno", "speaker" => "S0" },
        { "start" => 1.1, "end" => 2.0, "text" => "Dos", "translated_text" => "dos", "speaker" => "S1" }
      ]
      merged = job.send(:merge_segments_for_tts, segments)
      expect(merged.length).to eq(2)
    end

    it "does not merge across sentence boundaries" do
      segments = [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno.", "translated_text" => "Uno.", "speaker" => "S0" },
        { "start" => 1.1, "end" => 2.0, "text" => "Dos", "translated_text" => "dos", "speaker" => "S0" }
      ]
      merged = job.send(:merge_segments_for_tts, segments)
      expect(merged.length).to eq(2)
    end

    it "does not merge across a long gap" do
      segments = [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno", "translated_text" => "uno", "speaker" => "S0" },
        { "start" => 5.0, "end" => 6.0, "text" => "Dos", "translated_text" => "dos", "speaker" => "S0" }
      ]
      merged = job.send(:merge_segments_for_tts, segments)
      expect(merged.length).to eq(2)
    end
  end

  describe "#sanitize_for_tts" do
    let(:job) { described_class.new }

    it "replaces em-dashes and en-dashes with commas" do
      expect(job.send(:sanitize_for_tts, "wait—what")).to eq("wait, what")
      expect(job.send(:sanitize_for_tts, "wait – what")).to eq("wait, what")
    end

    it "collapses repeated commas and whitespace" do
      expect(job.send(:sanitize_for_tts, "uno,  ,  dos")).to eq("uno, dos")
    end
  end

  describe "#perform" do
    let(:task) do
      create(:dubbing_task, :with_audio, :with_vocals, :with_background,
        segments: [ {
          "start" => 0.0, "end" => 2.0, "text" => "Hello", "translated_text" => "Hola",
          "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral"
        } ]
      )
    end

    context "when the task is already in a terminal state" do
      it "returns without doing work" do
        task.update!(status: "failed")
        expect(Open3).not_to receive(:capture3)
        expect(Faraday).not_to receive(:new)
        described_class.new.perform(task.id)
      end
    end

    context "when mixing succeeds end-to-end" do
      let!(:workspaces) { stub_dubbing_workspace }

      before do
        # ffprobe and the mix script both go through capture3
        ffprobe_json = { format: { duration: "60.0" } }.to_json
        allow(Open3).to receive(:capture3).and_return([ ffprobe_json, "", double(success?: true) ])
        allow(File).to receive(:write)
        # Skip ElevenLabs/TTS round-trips by zeroing-out the segments-to-voice loop.
        allow_any_instance_of(described_class).to receive(:merge_segments_for_tts).and_return([])
        allow(DubbingPipeline::CreateHlsJob).to receive(:perform_later)
      end

      it "attaches dubbed.m4a only after the mix script succeeds" do
        described_class.new.perform(task.id)
        filenames = workspaces.first.attached.map { |a| a[:filename] }
        expect(filenames).to eq([ "dubbed.m4a" ])
      end

      it "enqueues CreateHlsJob" do
        expect(DubbingPipeline::CreateHlsJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end
    end

    context "when the mix script fails" do
      before do
        stub_dubbing_workspace
        # ffprobe (first capture3) succeeds, the mix script (second) fails
        allow(Open3).to receive(:capture3).and_return(
          [ { format: { duration: "60.0" } }.to_json, "", double(success?: true) ],
          [ "", "boom", double(success?: false) ]
        )
        allow(File).to receive(:write)
        allow_any_instance_of(described_class).to receive(:merge_segments_for_tts).and_return([])
      end

      it "does not persist segment changes if mixing fails" do
        original_segments = task.segments
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError)
        expect(task.reload.segments).to eq(original_segments)
      end
    end
  end
end
