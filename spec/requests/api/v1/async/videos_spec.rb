require "rails_helper"

RSpec.describe Api::V1::Async::VideosController, type: :controller do
  include_context "admin"
  include_context "ffmpeg video api"

  describe "GET #show" do
    let(:video) { create(:video) }
    let!(:transcoding_task) { create(:transcoding_task, video: video) }

    before do
      request.headers.merge!(auth_headers)
    end

    it "returns the video" do
      get :show, params: { id: video.id }

      expect(response).to have_http_status(:ok)
    end

    it "returns video details with transcoding tasks" do
      get :show, params: { id: video.id }

      json_response = JSON.parse(response.body)
      expect(json_response).to include("id", "external_video_link", "status", "transcoding_tasks")
      expect(json_response["transcoding_tasks"]).to be_an(Array)
    end
  end
end
