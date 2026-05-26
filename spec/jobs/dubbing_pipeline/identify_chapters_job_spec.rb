require "rails_helper"

RSpec.describe DubbingPipeline::IdentifyChaptersJob, type: :job do
  let(:task) do
    create(:dubbing_task,
      segments: [ { "start" => 0.0, "end" => 5.0, "text" => "intro" } ]
    )
  end

  let(:chapters_payload) do
    { "chapters" => [
      { "start" => 0.0, "title" => "Intro", "title_dubbed" => "Introducción" }
    ] }.to_json
  end

  let(:response) do
    body = { "choices" => [ { "message" => { "content" => chapters_payload } } ] }.to_json
    instance_double(Faraday::Response, success?: true, body: body)
  end

  let(:conn) { instance_double(Faraday::Connection, post: response) }

  before do
    allow(Faraday).to receive(:new).and_return(conn)
    allow(DubbingPipeline::TranslateJob).to receive(:perform_later)
  end

  describe "#perform" do
    it "writes chapters and enqueues TranslateJob" do
      described_class.new.perform(task.id)

      expect(task.reload.chapters).to eq([
        { "start" => 0.0, "title" => "Intro", "title_dubbed" => "Introducción" }
      ])
      expect(DubbingPipeline::TranslateJob).to have_received(:perform_later).with(task.id)
    end

    it "truncates titles longer than 60 chars" do
      long = "x" * 80
      payload = { "chapters" => [ { "start" => 0.0, "title" => long, "title_dubbed" => long } ] }.to_json
      allow(response).to receive(:body).and_return({ "choices" => [ { "message" => { "content" => payload } } ] }.to_json)

      described_class.new.perform(task.id)

      expect(task.reload.chapters.first["title"].length).to eq(60)
      expect(task.reload.chapters.first["title_dubbed"].length).to eq(60)
    end

    context "when GPT call fails" do
      let(:response) { instance_double(Faraday::Response, success?: false, status: 503, body: "down") }

      it "raises" do
        expect { described_class.new.perform(task.id) }.to raise_error(RuntimeError, /GPT chapters failed/)
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
end
