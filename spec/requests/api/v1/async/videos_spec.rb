require "rails_helper"

RSpec.describe Api::V1::Async::VideosController, type: :controller do
  include_context "admin"
  include_context "ffmpeg video api"

  describe "POST #create" do
    let(:transcoding_profile) { create(:transcoding_profile, :p720) }
    let(:video_params) do
      {
        external_video_link: "https://example.com/video.mp4",
        transcoding_profile_labels: [ transcoding_profile.label ]
      }
    end

    before do
      request.headers.merge!(auth_headers)
    end

    it "creates a video" do
      expect {
        post :create, params: video_params
      }.to change(Video, :count).by(1)
    end

    it "creates transcoding processes" do
      expect {
        post :create, params: video_params
      }.to change(Videos::TranscodingProcess, :count).by(1)
    end

    it "enqueues a transcode job" do
      expect {
        post :create, params: video_params
      }.to have_enqueued_job(Videos::TranscodeVideoJob)
    end

    it "returns created status" do
      post :create, params: video_params

      expect(response).to have_http_status(:created)
    end

    it "returns transcoding process information" do
      post :create, params: video_params

      json_response = JSON.parse(response.body)
      expect(json_response["transcoding_processes"]).to be_an(Array)
      expect(json_response["transcoding_processes"].first).to include(
        "id",
        "label",
        "status"
      )
    end
  end

  describe "GET #show" do
    let(:video) { create(:video) }
    let!(:transcoding_process) { create(:transcoding_process, video: video) }

    before do
      request.headers.merge!(auth_headers)
    end

    it "returns the video" do
      get :show, params: { id: video.id }

      expect(response).to have_http_status(:ok)
    end

    it "returns video details with transcoding processes" do
      get :show, params: { id: video.id }

      json_response = JSON.parse(response.body)
      expect(json_response).to include("id", "external_video_link", "status", "transcoding_processes")
      expect(json_response["transcoding_processes"]).to be_an(Array)
    end
  end

  describe "DELETE #destroy" do
    let!(:video) { create(:video) }

    before do
      request.headers.merge!(auth_headers)
    end

    it "destroys the video" do
      expect {
        delete :destroy, params: { id: video.id }
      }.to change(Video, :count).by(-1)
    end

    it "returns ok status" do
      delete :destroy, params: { id: video.id }

      expect(response).to have_http_status(:ok)
    end
  end
end
