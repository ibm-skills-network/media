require "rails_helper"

RSpec.describe DubbingPipeline::TranscribeJob, type: :job do
  let(:task) { create(:dubbing_task, :with_audio) }

  let(:sse_events) do
    [
      { "type" => "transcript.text.delta", "delta" => "Hello" },
      { "type" => "transcript.text.segment", "id" => "seg_1", "start" => 0.0, "end" => 1.0, "speaker" => "spk_a", "text" => "Hello" },
      { "type" => "transcript.text.segment", "id" => "seg_2", "start" => 1.0, "end" => 2.0, "speaker" => "spk_b", "text" => "world." }
    ]
  end

  let(:transcribe_status) { 200 }
  let(:transcribe_response) do
    instance_double(Faraday::Response, success?: transcribe_status == 200, status: transcribe_status)
  end

  let(:merge_response) do
    body = { "choices" => [ { "message" => { "content" => {
      "sentences" => [ { "start_marker" => "[0:0.00]", "text" => "Hello world." } ]
    }.to_json } } ] }.to_json
    instance_double(Faraday::Response, success?: true, body: body)
  end

  let(:conn) { instance_double(Faraday::Connection) }
  let(:request_bodies) { [] }

  before do
    stub_dubbing_workspace
    allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
    allow(Faraday).to receive(:new).and_return(conn)
    allow(DubbingPipeline::AnnotateAudioJob).to receive(:perform_later)
    allow(Faraday::Multipart::FilePart).to receive(:new).and_return(double("FilePart"))

    allow(conn).to receive(:post) do |_url, &block|
      req = Struct.new(:headers, :options, :body).new({}, Faraday::RequestOptions.new, nil)
      block.call(req)
      request_bodies << req.body

      if req.options.on_data
        # The transcription call streams SSE; deliver it in two chunks split
        # mid-event so a partial event has to survive in the buffer
        payload = sse_events.map { |e| "data: #{e.to_json}\n\n" }.join + "data: [DONE]\n\n"
        env = double(status: transcribe_status)
        middle = payload.length / 2
        req.options.on_data.call(payload[0...middle], middle, env)
        req.options.on_data.call(payload[middle..], payload.length, env)
        transcribe_response
      else
        merge_response
      end
    end
  end

  describe "#perform" do
    it "writes merged segments back to the task and remaps speakers" do
      described_class.new.perform(task.id)

      segs = task.reload.segments
      expect(segs.length).to eq(1)
      expect(segs.first["text"]).to eq("Hello world.")
      expect(segs.first["speaker"]).to eq("SPEAKER_0")
    end

    it "requests a streamed diarized transcription" do
      described_class.new.perform(task.id)

      body = request_bodies.first
      expect(body[:stream]).to eq("true")
      expect(body[:model]).to eq("gpt-4o-transcribe-diarize")
      expect(body[:response_format]).to eq("diarized_json")
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
      let(:transcribe_status) { 500 }

      it "raises without leaking the response body" do
        expect { described_class.new.perform(task.id) }
          .to raise_error(RuntimeError, /Transcription failed: HTTP 500\z/)
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
