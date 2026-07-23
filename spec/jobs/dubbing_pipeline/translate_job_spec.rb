require "rails_helper"

RSpec.describe DubbingPipeline::TranslateJob, type: :job do
  let(:segments) do
    [
      { "start" => 0.0, "end" => 1.0, "text" => "Hello.", "speaker" => "SPEAKER_0" },
      { "start" => 1.0, "end" => 2.0, "text" => "World.", "speaker" => "SPEAKER_0" }
    ]
  end

  let(:task) { create(:dubbing_task, segments: segments) }

  let(:gpt_content) { "[0|1.0s|1w] Hola.\n[1|1.0s|1w] Mundo." }
  let(:response) do
    body = { "choices" => [ { "message" => { "content" => gpt_content } } ] }.to_json
    instance_double(Faraday::Response, success?: true, body: body)
  end

  let(:conn) { instance_double(Faraday::Connection, post: response) }

  before do
    allow(Faraday).to receive(:new).and_return(conn)
    allow(DubbingPipeline::GenerateDubbedAudioJob).to receive(:perform_later)
  end

  describe "#perform" do
    it "assigns translated_text to each segment" do
      described_class.new.perform(task.id)

      segs = task.reload.segments
      expect(segs.map { |s| s["translated_text"] }).to eq([ "Hola.", "Mundo." ])
    end

    it "writes subtitle_segments alongside segments" do
      described_class.new.perform(task.id)
      expect(task.reload.subtitle_segments.map { |s| s["translated_text"] }).to eq([ "Hola.", "Mundo." ])
    end

    it "enqueues GenerateDubbedAudioJob" do
      expect(DubbingPipeline::GenerateDubbedAudioJob).to receive(:perform_later).with(task.id)
      described_class.new.perform(task.id)
    end

    context "when GPT echoes the budget tag back in its output" do
      let(:gpt_content) { "[0|1.0s|max 3 words] Hola.\n[1|1.0s|max 3 words] Mundo." }

      it "still parses every translation" do
        described_class.new.perform(task.id)
        expect(task.reload.segments.map { |s| s["translated_text"] }).to eq([ "Hola.", "Mundo." ])
      end
    end

    context "when GPT omits more than 10% of translations" do
      let(:gpt_content) { "" } # nothing parsed

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /Translation incomplete/)
      end
    end

    context "when the task is already in a terminal state" do
      it "returns without calling the API" do
        task.update!(status: "failed")
        expect(conn).not_to receive(:post)
        described_class.new.perform(task.id)
      end
    end
  end

  describe "#length_budget" do
    let(:job) { described_class.new }

    it "computes a word budget from duration and the language's TTS pace" do
      expect(job.send(:length_budget, 3.8, "Spanish")).to eq("max 8 words")
    end

    it "never drops below the minimum budget on tiny slots" do
      expect(job.send(:length_budget, 0.5, "Spanish")).to eq("max 3 words")
    end

    it "uses character budgets for CJK languages" do
      expect(job.send(:length_budget, 4.0, "Japanese")).to eq("max 26 characters")
    end
  end

  describe "#build_batches" do
    let(:job) { described_class.new }

    it "produces contiguous translate ranges that cover every segment" do
      segments = Array.new(40) { |i| { "start" => i.to_f, "end" => i + 1.0, "text" => "t#{i}" } }
      batches = job.send(:build_batches, segments)

      covered = batches.flat_map { |b| b[:translate_range].to_a }
      expect(covered).to eq((0...40).to_a)
    end

    it "gives each non-first batch a context window of up to CONTEXT_OVERLAP" do
      segments = Array.new(40) { |i| { "start" => i.to_f, "end" => i + 1.0, "text" => "t#{i}" } }
      batches = job.send(:build_batches, segments)

      expect(batches.first[:context_range].size).to eq(0)
      batches.drop(1).each do |b|
        expect(b[:context_range].size).to eq(described_class::CONTEXT_OVERLAP)
      end
    end
  end
end
