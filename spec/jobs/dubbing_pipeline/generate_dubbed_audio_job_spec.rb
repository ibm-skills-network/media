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

  describe "#retranslate_shorter" do
    let(:job) { described_class.new }

    def prompt_for(text:, target_lang:, clip_s: 5.0, slot_s: 2.5)
      captured = nil
      req = Struct.new(:headers, :options, :body).new({}, Faraday::RequestOptions.new, nil)
      conn = instance_double(Faraday::Connection)
      allow(conn).to receive(:post) do |&block|
        block.call(req)
        captured = req.body
        instance_double(Faraday::Response, success?: true,
          body: { "choices" => [ { "message" => { "content" => "shorter" } } ] }.to_json)
      end
      allow(Faraday).to receive(:new).and_return(conn)

      job.send(:retranslate_shorter, text, "original", clip_s, slot_s, target_lang)
      JSON.parse(captured).dig("messages", 0, "content")
    end

    it "budgets Latin-script languages in words via whitespace splitting" do
      prompt = prompt_for(text: "uno dos tres cuatro cinco seis", target_lang: "Spanish")
      expect(prompt).to include("AT MOST 3 words (it currently has 6)")
    end

    it "budgets char-based languages in characters, not whitespace tokens" do
      # .split would count this 10-character string as a single token
      prompt = prompt_for(text: "こんにちは世界テスト", target_lang: "Japanese")
      expect(prompt).to include("characters (it currently has 10)")
      expect(prompt).not_to include("has 1)")
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

    it "records which source segments each merged segment covers" do
      segments = [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno", "translated_text" => "uno", "speaker" => "S0" },
        { "start" => 1.2, "end" => 2.0, "text" => "Dos", "translated_text" => "dos", "speaker" => "S0" },
        { "start" => 5.0, "end" => 6.0, "text" => "Tres", "translated_text" => "tres", "speaker" => "S0" }
      ]
      merged = job.send(:merge_segments_for_tts, segments)
      expect(merged.map { |s| s["source_range"] }).to eq([ [ 0, 1 ], [ 2, 2 ] ])
    end

    it "never merges a fallback segment into a spoken one" do
      # segment 1 uses original audio, so it can't share a TTS clip with 0 or 2
      segments = [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno", "translated_text" => "uno", "speaker" => "S0" },
        { "start" => 1.1, "end" => 2.0, "text" => "Dos", "translated_text" => "Dos",
          "speaker" => "S0", "use_original_audio" => true },
        { "start" => 2.1, "end" => 3.0, "text" => "Tres", "translated_text" => "tres", "speaker" => "S0" }
      ]
      merged = job.send(:merge_segments_for_tts, segments)
      expect(merged.length).to eq(3)
      expect(merged[1]["use_original_audio"]).to be(true)
    end
  end

  describe "#rebuild_subtitle_segments" do
    let(:job) { described_class.new }
    let(:subtitles) do
      [
        { "start" => 0.0, "end" => 1.0, "text" => "Uno", "translated_text" => "uno", "speaker" => "S0" },
        { "start" => 1.2, "end" => 2.0, "text" => "Dos", "translated_text" => "dos", "speaker" => "S0" },
        { "start" => 5.0, "end" => 6.0, "text" => "Tres.", "translated_text" => "tres.", "speaker" => "S0" }
      ]
    end

    it "collapses the cues behind a retranslated segment into one cue with the spoken text" do
      merged = [
        { "start" => 0.0, "end" => 2.0, "text" => "Uno Dos", "translated_text" => "corto",
          "speaker" => "S0", "source_range" => [ 0, 1 ], "retranslated" => true },
        { "start" => 5.0, "end" => 6.0, "text" => "Tres.", "translated_text" => "tres.",
          "speaker" => "S0", "source_range" => [ 2, 2 ], "retranslated" => false }
      ]

      rebuilt = job.send(:rebuild_subtitle_segments, subtitles, merged, 3)

      expect(rebuilt.length).to eq(2)
      expect(rebuilt.first).to eq(
        { "start" => 0.0, "end" => 2.0, "text" => "Uno Dos", "translated_text" => "corto", "speaker" => "S0" }
      )
      expect(rebuilt.last).to eq(subtitles.last)
    end

    it "returns the snapshot untouched when nothing was retranslated" do
      merged = [ { "source_range" => [ 0, 2 ], "retranslated" => false } ]
      expect(job.send(:rebuild_subtitle_segments, subtitles, merged, 3)).to equal(subtitles)
    end

    it "leaves a snapshot with unexpected length alone rather than misaligning cues" do
      merged = [ { "source_range" => [ 0, 1 ], "retranslated" => true } ]
      expect(job.send(:rebuild_subtitle_segments, subtitles, merged, 5)).to equal(subtitles)
    end

    it "passes through a blank snapshot" do
      expect(job.send(:rebuild_subtitle_segments, [], [], 0)).to eq([])
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
        # Covers both ffprobe (duration string) and the mix script (success)
        allow(Open3).to receive(:capture3).and_return([ "60.0", "", double(success?: true) ])
        allow(File).to receive(:write)
        # Skip ElevenLabs/TTS round-trips by zeroing-out the segments-to-voice loop
        allow_any_instance_of(described_class).to receive(:merge_segments_for_tts).and_return([])
        allow(DubbingPipeline::CreateDubbedVideoJob).to receive(:perform_later)
      end

      it "attaches dubbed.m4a only after the mix script succeeds" do
        described_class.new.perform(task.id)
        filenames = workspaces.first.attached.map { |a| a[:filename] }
        expect(filenames).to eq([ "dubbed.m4a" ])
      end

      it "enqueues CreateDubbedVideoJob" do
        expect(DubbingPipeline::CreateDubbedVideoJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end
    end

    context "when a segment is retranslated during TTS" do
      let(:source_segments) do
        [
          { "start" => 0.0, "end" => 1.0, "text" => "Hello", "translated_text" => "Hola amigo",
            "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral" },
          { "start" => 1.2, "end" => 2.0, "text" => "world", "translated_text" => "mundo grande",
            "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral" },
          { "start" => 5.0, "end" => 6.0, "text" => "Bye.", "translated_text" => "Adios.",
            "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral" }
        ]
      end

      let(:task) do
        create(:dubbing_task, :with_audio, :with_vocals, :with_background,
          segments: source_segments, subtitle_segments: source_segments)
      end

      before do
        stub_dubbing_workspace
        allow(Open3).to receive(:capture3).and_return([ "60.0", "", double(success?: true) ])
        allow(File).to receive(:write)
        allow_any_instance_of(DubbingTask).to receive(:voice_for).and_return("v1")
        # First merged segment (sources 0-1) comes back shortened, second unchanged
        allow_any_instance_of(described_class).to receive(:generate_tts_with_retranslation)
          .and_return([ "/tts/0.mp3", "Hola mundo" ], [ "/tts/1.mp3", "Adios." ])
        allow(DubbingPipeline::CreateDubbedVideoJob).to receive(:perform_later)
      end

      it "collapses the retranslated cues in subtitle_segments to the spoken text" do
        described_class.new.perform(task.id)

        subs = task.reload.subtitle_segments
        expect(subs.length).to eq(2)
        expect(subs.first["translated_text"]).to eq("Hola mundo")
        expect(subs.first.values_at("start", "end")).to eq([ 0.0, 2.0 ])
        expect(subs.first["text"]).to eq("Hello world")
        expect(subs.last["translated_text"]).to eq("Adios.")
      end

      it "does not leak merge bookkeeping keys into persisted segments" do
        described_class.new.perform(task.id)

        all_keys = task.reload.segments.flat_map(&:keys) + task.subtitle_segments.flat_map(&:keys)
        expect(all_keys).not_to include("source_range", "retranslated")
      end
    end

    context "when a segment is flagged to use original audio" do
      let(:task) do
        create(:dubbing_task, :with_audio, :with_vocals, :with_background,
          segments: [
            { "start" => 0.0, "end" => 1.0, "text" => "Hello", "translated_text" => "Hola",
              "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral" },
            { "start" => 2.0, "end" => 4.0, "text" => "world", "translated_text" => "world",
              "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral",
              "use_original_audio" => true }
          ]
        )
      end

      let(:written) { {} }

      before do
        stub_dubbing_workspace
        allow(Open3).to receive(:capture3).and_return([ "60.0", "", double(success?: true) ])
        allow(File).to receive(:write) { |path, body| written[File.basename(path)] = body }
        allow_any_instance_of(DubbingTask).to receive(:voice_for).and_return("v1")
        # spoken segment yields a clip; fallback segment must never reach TTS
        allow_any_instance_of(described_class).to receive(:generate_tts_with_retranslation)
          .and_return([ "/tts/0.mp3", "Hola" ])
        allow(DubbingFfprobe).to receive(:duration_seconds).and_return(60.0)
        allow(DubbingPipeline::CreateDubbedVideoJob).to receive(:perform_later)
      end

      it "writes the fallback segment's time range to the fallback-ranges file" do
        described_class.new.perform(task.id)
        expect(JSON.parse(written["mix_fallback_ranges.json"])).to eq([ [ 2.0, 4.0 ] ])
      end

      it "does not generate a TTS clip for the fallback segment" do
        described_class.new.perform(task.id)
        # only the spoken segment (index 0) ends up in the tts files manifest
        tts = JSON.parse(written["mix_tts_files.json"])
        expect(tts.map { |f| f["index"] }).to eq([ 0 ])
      end

      it "strips use_original_audio from persisted segments" do
        described_class.new.perform(task.id)
        all_keys = task.reload.segments.flat_map(&:keys)
        expect(all_keys).not_to include("use_original_audio")
      end
    end

    context "when the mix script fails" do
      before do
        stub_dubbing_workspace
        allow(Open3).to receive(:capture3).and_return([ "60.0", "boom", double(success?: false) ])
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
