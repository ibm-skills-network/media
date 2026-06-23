require "rails_helper"

RSpec.describe Api::V1::Async::Videos::DubbingTasksController, type: :controller do
  include_context "admin"

  describe "GET #show" do
    let(:task) { create(:dubbing_task, status: "processing") }

    it "returns ok" do
      get :show, params: { id: task.id }
      expect(response).to have_http_status(:ok)
    end

    it "returns status and error_message" do
      task.update!(status: "failed", error_message: "boom")

      get :show, params: { id: task.id }

      json = JSON.parse(response.body)
      expect(json).to include("status" => "failed", "error_message" => "boom")
    end

    it "returns hls_path so the client can fetch the playable manifest" do
      task.update!(status: "success", hls_path: "/api/v1/async/videos/dubbing_tasks/#{task.id}/hls/master.m3u8")

      get :show, params: { id: task.id }

      json = JSON.parse(response.body)
      expect(json["hls_path"]).to end_with("/master.m3u8")
    end
  end

  describe "GET #hls" do
    let(:task) { create(:dubbing_task, status: "success") }
    let(:bucket) { double("bucket") }
    let(:object) { double("object") }

    before do
      service = double("service", bucket: bucket)
      allow(ActiveStorage::Blob).to receive(:service).and_return(service)
      allow(bucket).to receive(:object).and_return(object)
      allow(object).to receive(:exists?).and_return(true)
      allow(object).to receive(:get).and_yield("chunk1").and_yield("chunk2")
    end

    it "streams master.m3u8 with the correct content type" do
      get :hls, params: { id: task.id, path: "master.m3u8" }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("application/vnd.apple.mpegurl")
      expect(bucket).to have_received(:object).with("dubbing/#{task.id}/hls/master.m3u8")
    end

    it "streams an fMP4 segment with video/iso.segment" do
      get :hls, params: { id: task.id, path: "seg_v_000.mp4" }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with("video/iso.segment")
    end

    it "rejects path traversal attempts" do
      get :hls, params: { id: task.id, path: "../../etc/passwd" }
      expect(response).to have_http_status(:not_found)
      expect(bucket).not_to have_received(:object)
    end

    it "rejects absolute paths" do
      get :hls, params: { id: task.id, path: "/etc/passwd" }
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the COS object is missing" do
      allow(object).to receive(:exists?).and_return(false)
      get :hls, params: { id: task.id, path: "master.m3u8" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        dubbing_task: {
          video_url: "https://example.com/video.mp4",
          language: "Spanish",
          dialect: "latin-american"
        }
      }
    end

    it "creates a DubbingTask" do
      expect {
        post :create, params: valid_params
      }.to change(DubbingTask, :count).by(1)
    end

    it "enqueues ExtractAudioJob with the task id" do
      expect {
        post :create, params: valid_params
      }.to have_enqueued_job(DubbingPipeline::ExtractAudioJob).with(kind_of(Integer))
    end

    it "returns created with the task id and status" do
      post :create, params: valid_params

      json = JSON.parse(response.body)
      expect(response).to have_http_status(:created)
      expect(json).to include("id", "status" => "pending")
    end

    context "when validation fails" do
      it "returns 422 with errors and does not enqueue a job" do
        bad_params = valid_params.deep_merge(dubbing_task: { language: "Klingon" })

        expect {
          post :create, params: bad_params
        }.not_to have_enqueued_job(DubbingPipeline::ExtractAudioJob)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to have_key("errors")
      end
    end
  end
end
