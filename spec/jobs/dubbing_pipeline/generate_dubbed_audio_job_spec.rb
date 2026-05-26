require "rails_helper"

RSpec.describe DubbingPipeline::GenerateDubbedAudioJob, type: :job do
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
      create(:dubbing_task,
        background_path: "/tmp/dubbing/1/background.wav",
        vocals_path:     "/tmp/dubbing/1/vocals.wav",
        audio_path:      "/tmp/dubbing/1/audio.wav",
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
  end
end
