require "rails_helper"

RSpec.describe Api::V1::Async::VideosController, type: :controller do
  include_context "admin"
  include_context "ffmpeg video api"

  describe "POST #create" do
    let(:transcoding_profile) { create(:transcoding_profile, :p720) }
    let(:video_params) do
      {
        external_video_link: "https://example.com/video.mp4",
        transcoding_profile_labels: [transcoding_profile.label]
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
end
