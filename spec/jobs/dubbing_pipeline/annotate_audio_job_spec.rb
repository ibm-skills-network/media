require "rails_helper"

RSpec.describe DubbingPipeline::AnnotateAudioJob, type: :job do
  let(:task) do
    create(:dubbing_task, :with_vocals,
      segments: [ { "start" => 0.0, "end" => 1.0, "text" => "hi", "speaker" => "SPEAKER_0" } ]
    )
  end

  describe "#perform" do
    before do
      stub_dubbing_workspace
      allow(File).to receive(:write)
    end

    context "when annotate_audio.py succeeds" do
      let(:annotated_json) do
        [ {
          "start" => 0.0, "end" => 1.0, "text" => "hi",
          "speaker" => "SPEAKER_0", "gender" => "man", "prosody" => "neutral"
        } ].to_json
      end

      before do
        allow(Open3).to receive(:capture3).and_return([ annotated_json, "", double(success?: true) ])
        allow(DubbingPipeline::IdentifyChaptersJob).to receive(:perform_later)
      end

      it "writes gender and prosody back onto segments" do
        described_class.new.perform(task.id)

        first = task.reload.segments.first
        expect(first["gender"]).to eq("man")
        expect(first["prosody"]).to eq("neutral")
      end

      it "enqueues IdentifyChaptersJob" do
        expect(DubbingPipeline::IdentifyChaptersJob).to receive(:perform_later).with(task.id)
        described_class.new.perform(task.id)
      end
    end

    context "when the script fails" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "annotate error", double(success?: false) ])
      end

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /Audio annotation failed/)
      end
    end

    context "when the task is already failed" do
      it "returns without shelling out" do
        task.update!(status: "failed")
        expect(Open3).not_to receive(:capture3)
        described_class.new.perform(task.id)
      end
    end

    context "when vocals are not attached yet" do
      let(:task) do
        create(:dubbing_task,
          segments: [ { "start" => 0.0, "end" => 1.0, "text" => "hi", "speaker" => "SPEAKER_0" } ]
        )
      end

      it "re-enqueues itself with a delay instead of running or raising" do
        expect(Open3).not_to receive(:capture3)
        delayed = double("delayed")
        expect(described_class).to receive(:set)
          .with(wait: described_class::WAIT_FOR_VOCALS_S).and_return(delayed)
        expect(delayed).to receive(:perform_later).with(task.id, 1)

        described_class.new.perform(task.id)
      end

      it "carries the wait count forward so the backoff is bounded" do
        delayed = double("delayed")
        allow(described_class).to receive(:set).and_return(delayed)
        expect(delayed).to receive(:perform_later).with(task.id, 6)

        described_class.new.perform(task.id, 5)
      end

      it "gives up once the wait budget is spent so Sidekiq fails the task" do
        expect {
          described_class.new.perform(task.id, described_class::MAX_VOCALS_WAITS)
        }.to raise_error(RuntimeError, /Vocals never became available/)
      end

      it "stops waiting when the task has gone terminal" do
        task.update!(status: "failed")
        expect(described_class).not_to receive(:set)
        described_class.new.perform(task.id)
      end
    end
  end
end
