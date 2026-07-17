require "rails_helper"

RSpec.describe DubbingPipeline::TranscribeJob, type: :job do
  let(:task) { create(:dubbing_task, :with_audio) }

  let(:sse_events) do
    [
      { "type" => "transcript.text.delta", "delta" => "Hello" },
      { "type" => "transcript.text.segment", "id" => "seg_1", "start" => 0.0, "end" => 1.0, "speaker" => "A", "text" => "Hello" },
      { "type" => "transcript.text.segment", "id" => "seg_2", "start" => 1.0, "end" => 2.0, "speaker" => "B", "text" => "world." }
    ]
  end

  # The live API delimits events with CRLF; the stub mirrors that
  let(:terminal_payload) do
    "data: #{{ "type" => "transcript.text.done", "text" => "Hello world." }.to_json}\r\n\r\ndata: [DONE]\r\n\r\n"
  end
  let(:stream_payload) do
    sse_events.map { |e| "data: #{e.to_json}\r\n\r\n" }.join + terminal_payload
  end

  let(:transcribe_status) { 200 }
  let(:stream_env) { double(status: transcribe_status) }
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
  let(:transcribe_request_bodies) { [] }

  before do
    stub_dubbing_workspace
    allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: true) ])
    allow(DubbingFfprobe).to receive(:duration_seconds).and_return(60.0)
    allow(Faraday).to receive(:new).and_return(conn)
    allow(Faraday::Multipart::FilePart).to receive(:new).and_return(double("FilePart"))
    allow(DubbingPipeline::AnnotateAudioJob).to receive(:perform_later)

    allow(conn).to receive(:post) do |url, &block|
      req = Struct.new(:headers, :options, :body).new({}, Faraday::RequestOptions.new, nil)
      block.call(req)

      if url.include?("audio/transcriptions")
        transcribe_request_bodies << req.body

        # Split mid-event so a partial event has to survive in the buffer
        middle = stream_payload.length / 2
        req.options.on_data.call(stream_payload[0...middle], middle, stream_env)
        req.options.on_data.call(stream_payload[middle..], stream_payload.length, stream_env)
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
      expect(segs.first.values_at("start", "end")).to eq([ 0.0, 2.0 ])
    end

    it "enqueues AnnotateAudioJob" do
      expect(DubbingPipeline::AnnotateAudioJob).to receive(:perform_later).with(task.id)
      described_class.new.perform(task.id)
    end

    it "requests a streamed diarized transcription" do
      described_class.new.perform(task.id)

      body = transcribe_request_bodies.first
      expect(body[:stream]).to eq("true")
      expect(body[:model]).to eq("gpt-4o-transcribe-diarize")
      expect(body[:response_format]).to eq("diarized_json")
    end

    it "tolerates adapters that don't expose the status mid-stream" do
      allow(stream_env).to receive(:status).and_return(nil)

      described_class.new.perform(task.id)

      expect(task.reload.segments.length).to eq(1)
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
      let(:stream_payload) { '{"error":{"message":"insufficient quota"}}' }

      it "raises with the error body for diagnosis" do
        expect { described_class.new.perform(task.id) }
          .to raise_error(RuntimeError, /Transcription failed: HTTP 500.*insufficient quota/)
      end
    end

    context "when the stream ends without a terminal event" do
      let(:terminal_payload) { "" }

      it "raises instead of accepting a possibly-truncated transcript" do
        expect { described_class.new.perform(task.id) }
          .to raise_error(RuntimeError, /ended without a terminal event/)
        expect(DubbingPipeline::AnnotateAudioJob).not_to have_received(:perform_later)
      end
    end

    context "when the stream completes with no speech segments" do
      let(:sse_events) { [] }

      it "raises instead of producing a silent dub" do
        expect { described_class.new.perform(task.id) }
          .to raise_error(RuntimeError, /no speech segments/)
      end
    end

    context "when the stream sends an unparseable event" do
      let(:stream_payload) { "data: {not json\r\n\r\n" + terminal_payload }

      it "raises with the offending payload" do
        expect { described_class.new.perform(task.id) }
          .to raise_error(RuntimeError, /unparseable event: \{not json/)
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
