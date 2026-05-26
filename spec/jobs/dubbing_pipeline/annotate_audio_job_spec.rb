require "rails_helper"

RSpec.describe DubbingPipeline::AnnotateAudioJob, type: :job do
  let(:task) do
    create(:dubbing_task,
      vocals_path: "/tmp/dubbing/1/vocals.wav",
      segments: [ { "start" => 0.0, "end" => 1.0, "text" => "hi", "speaker" => "SPEAKER_0" } ]
    )
  end

  describe "#perform" do
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
  end
end
