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
        # ffprobe and the mix script both go through capture3; the ffprobe call
        # returns the duration string, the mix call returns success.
        allow(Open3).to receive(:capture3).and_return([ "60.0", "", double(success?: true) ])
        allow(File).to receive(:write)
        # Skip ElevenLabs/TTS round-trips by zeroing-out the segments-to-voice loop.
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
