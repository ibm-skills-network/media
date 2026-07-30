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

    context "when a segment drops out of the first pass but the retry recovers it" do
      # First pass returns only segment 0; the missing-segment retry then fills in 1.
      let(:first_pass) { instance_double(Faraday::Response, success?: true, body: { "choices" => [ { "message" => { "content" => "[0|1.0s] Hola." } } ] }.to_json) }
      let(:retry_pass) { instance_double(Faraday::Response, success?: true, body: { "choices" => [ { "message" => { "content" => "[1|1.0s] Mundo." } } ] }.to_json) }

      before { allow(conn).to receive(:post).and_return(first_pass, retry_pass) }

      it "does not fall back for the recovered segment" do
        described_class.new.perform(task.id)
        segs = task.reload.segments
        expect(segs.map { |s| s["translated_text"] }).to eq([ "Hola.", "Mundo." ])
        expect(segs.map { |s| s["use_original_audio"] }).to eq([ nil, nil ])
      end
    end

    context "when a segment is still missing after retries" do
      # 20 segments keeps a single fallback under the 10% incomplete-translation ceiling.
      let(:segments) do
        Array.new(20) { |i| { "start" => i.to_f, "end" => i + 1.0, "text" => "Line #{i}.", "speaker" => "SPEAKER_0" } }
      end
      # Every call returns all lines except index 1, which stays missing throughout.
      let(:gpt_content) do
        (0...20).reject { |i| i == 1 }.map { |i| "[#{i}|1.0s] T#{i}." }.join("\n")
      end

      it "keeps the original text and flags it to use original audio" do
        described_class.new.perform(task.id)
        seg = task.reload.segments[1]
        expect(seg["translated_text"]).to eq("Line 1.")
        expect(seg["use_original_audio"]).to be(true)
      end

      it "does not flag segments that were translated" do
        described_class.new.perform(task.id)
        expect(task.reload.segments[0]["use_original_audio"]).to be_nil
      end

      it "retries the missing segment MAX_MISSING_RETRIES times before giving up" do
        # first-pass batches (20 segments / BATCH_SIZE) + one retry post per round.
        first_pass_batches = described_class.new.send(:build_batches, segments).size
        expect(conn).to receive(:post)
          .exactly(first_pass_batches + described_class::MAX_MISSING_RETRIES).times
          .and_return(response)
        described_class.new.perform(task.id)
      end
    end
  end

  describe "#contiguous_runs" do
    let(:job) { described_class.new }

    it "groups consecutive indices into inclusive ranges" do
      expect(job.send(:contiguous_runs, [ 1, 2, 3, 7, 8, 11 ])).to eq([ 1..3, 7..8, 11..11 ])
    end

    it "returns an empty array for no indices" do
      expect(job.send(:contiguous_runs, [])).to eq([])
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

    it "emits a two-sided band with an aim and a hard ceiling" do
      expect(job.send(:length_budget, 3.8, "one two three four five", "Spanish"))
        .to eq("aim ~11, max 12 words")
    end

    it "floors the aim at the faithful source length so a fitting line is never compressed" do
      # A 12-word source in 3.8s fits; the aim should track the source, not shrink below it.
      expect(job.send(:length_budget, 3.8, "a b c d e f g h i j k l", "Spanish"))
        .to eq("aim ~12, max 12 words")
    end

    it "clamps the aim down to the hard ceiling when the source is too wordy to fit" do
      # 20-word source in 2.0s cannot fit; aim must not exceed the ceiling.
      budget = job.send(:length_budget, 2.0, ("word " * 20).strip, "Spanish")
      aim = budget[/aim ~(\d+)/, 1].to_i
      cap = budget[/max (\d+)/, 1].to_i
      expect(aim).to eq(cap)
    end

    it "never drops below the minimum budget on tiny slots" do
      expect(job.send(:length_budget, 0.5, "hi there", "Spanish")).to eq("aim ~3, max 3 words")
    end

    it "uses character budgets for CJK languages" do
      expect(job.send(:length_budget, 4.0, ("w " * 8).strip, "Japanese"))
        .to eq("aim ~28, max 33 characters")
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
