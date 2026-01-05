require "rails_helper"

RSpec.describe Api::V1::Async::Videos::CreateFromImagesController, type: :controller do
  include_context "admin"

  describe "POST #create" do
    let(:video_params) do
      {
        chunks: [
          { image_url: "https://example.com/image1.png", audio_url: "https://example.com/audio1.mp3" },
          { image_url: "https://example.com/image2.png", audio_url: "https://example.com/audio2.mp3" }
        ]
      }
    end

    before do
      request.headers.merge!(auth_headers)
    end

    it "creates a video with pending status" do
      expect {
        post :create, params: video_params
      }.to change(Video, :count).by(1)

      expect(Video.last.status).to eq("pending")
    end

    it "enqueues CreateFromImagesJob" do
      expect {
        post :create, params: video_params
      }.to have_enqueued_job(Videos::CreateFromImagesJob)
    end

    it "returns created status" do
      post :create, params: video_params

      expect(response).to have_http_status(:created)
    end

    it "returns video id and status" do
      post :create, params: video_params

      json_response = JSON.parse(response.body)
      expect(json_response["video"]).to include("id", "status")
      expect(json_response["video"]["status"]).to eq("pending")
    end

    context "with presigned_url" do
      let(:video_params_with_presigned) do
        video_params.merge(presigned_url: "https://example.com/presigned")
      end

      it "passes presigned_url to the job" do
        post :create, params: video_params_with_presigned

        expect(Videos::CreateFromImagesJob).to have_been_enqueued.with(
          anything,
          anything,
          presigned_url: "https://example.com/presigned"
        )
      end
    end
  end
end
