require "rails_helper"

RSpec.describe DubbingPipeline::TranscribeJob, type: :job do
  let(:task) { create(:dubbing_task, audio_path: "/tmp/dubbing/1/audio.wav") }

  let(:transcribe_response) do
    instance_double(Faraday::Response, success?: true, body: {
      "segments" => [
        { "start" => 0.0, "end" => 1.0, "speaker" => "spk_a", "text" => "Hello" },
        { "start" => 1.0, "end" => 2.0, "speaker" => "spk_b", "text" => "world." }
      ]
    }.to_json)
  end

  let(:merge_response) do
    body = { "choices" => [ { "message" => { "content" => {
      "sentences" => [ { "start_marker" => "[0:0.00]", "text" => "Hello world." } ]
    }.to_json } } ] }.to_json
    instance_double(Faraday::Response, success?: true, body: body)
  end

  let(:conn) { instance_double(Faraday::Connection) }

  before do
    allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
    allow(Faraday).to receive(:new).and_return(conn)
    allow(conn).to receive(:post).and_return(transcribe_response, merge_response)
    allow(DubbingPipeline::AnnotateAudioJob).to receive(:perform_later)
    allow(Faraday::Multipart::FilePart).to receive(:new).and_return(double("FilePart"))
  end

  describe "#perform" do
    it "writes merged segments back to the task and remaps speakers" do
      described_class.new.perform(task.id)

      segs = task.reload.segments
      expect(segs.length).to eq(1)
      expect(segs.first["text"]).to eq("Hello world.")
      expect(segs.first["speaker"]).to eq("SPEAKER_0")
    end

    it "enqueues AnnotateAudioJob" do
      expect(DubbingPipeline::AnnotateAudioJob).to receive(:perform_later).with(task.id)
      described_class.new.perform(task.id)
    end

    context "when ffmpeg compression fails" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "ffmpeg err", double(success?: false) ])
      end

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /ffmpeg compression failed/)
      end
    end

    context "when the transcribe call fails" do
      let(:transcribe_response) do
        instance_double(Faraday::Response, success?: false, status: 500, body: "boom")
      end

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /Transcription failed/)
      end
    end

    context "when the task is already in a terminal state" do
      it "returns without doing work" do
        task.update!(status: "success")
        expect(Open3).not_to receive(:capture3)
        described_class.new.perform(task.id)
      end
    end
  end
end
