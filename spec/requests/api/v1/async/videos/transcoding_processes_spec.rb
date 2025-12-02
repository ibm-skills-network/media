require "rails_helper"

RSpec.describe Api::V1::Async::Videos::TranscodingProcessesController, type: :controller do
  include_context "admin"
  include_context "ffmpeg video api"

  describe "GET #show" do
    let(:transcoding_profile) { create(:transcoding_profile, :p720) }
    let(:video) { create(:video, external_video_link: "https://example.com/video.mp4") }
    let(:transcoding_process) { create(:transcoding_process, video: video, transcoding_profile: transcoding_profile) }

    before do
      request.headers.merge!(auth_headers)
    end

    it "returns success status" do
      get :show, params: { id: transcoding_process.id }

      expect(response).to have_http_status(:ok)
    end

    it "returns transcoding process information" do
      get :show, params: { id: transcoding_process.id }

      json_response = JSON.parse(response.body)
      expect(json_response).to include(
        "status" => transcoding_process.status,
        "label" => transcoding_profile.label
      )
    end

    it "returns url when video file is attached" do
      get :show, params: { id: transcoding_process.id }

      json_response = JSON.parse(response.body)
      expect(json_response).to have_key("url")
    end
  end
end
