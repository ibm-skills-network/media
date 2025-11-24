require "rails_helper"

RSpec.describe Api::V1::Async::Videos::QualitiesController, type: :request do
  include_context "ffmpeg video api"
  include_context "admin"

  describe "POST /api/v1/async/videos/qualities" do
    let(:transcoding_profile) { create(:transcoding_profile, label: "720p") }
    let(:valid_params) do
      {
        external_video_link: "https://example.com/video.mp4",
        transcoding_profile_label: transcoding_profile.label
      }
    end

    context "with valid parameters" do
      it "creates a new quality" do
        expect {
          post "/api/v1/async/videos/qualities", params: valid_params, headers: auth_headers
        }.to change(Videos::Quality, :count).by(1)
      end

      it "returns created status and quality data" do
        post "/api/v1/async/videos/qualities", params: valid_params, headers: auth_headers

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json).to include("id", "label", "status")
      end

      it "enqueues the video encoding job" do
        expect(Videos::EncodeQualityJob).to receive(:perform_later)

        post "/api/v1/async/videos/qualities", params: valid_params, headers: auth_headers
      end
    end

    context "with invalid parameters" do
      it "returns not found for invalid transcoding profile" do
        invalid_params = valid_params.merge(transcoding_profile_label: "nonexistent")

        post "/api/v1/async/videos/qualities", params: invalid_params, headers: auth_headers

        expect(response).to have_http_status(:not_found)
      end

      it "returns unauthorized without auth token" do
        post "/api/v1/async/videos/qualities", params: valid_params

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /api/v1/async/videos/qualities/:id" do
    let(:transcoding_profile) { create(:transcoding_profile, label: "1080p") }
    let(:quality) { create(:quality, transcoding_profile: transcoding_profile) }

    context "when quality exists" do
      it "returns the quality status and details" do
        get "/api/v1/async/videos/qualities/#{quality.id}", headers: auth_headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json).to include("status", "url", "label")
        expect(json["label"]).to eq(transcoding_profile.label)
      end

      it "returns nil url when video file is not attached" do
        quality.video_file.purge if quality.video_file.attached?

        get "/api/v1/async/videos/qualities/#{quality.id}", headers: auth_headers

        json = JSON.parse(response.body)
        expect(json["url"]).to be_nil
      end
    end

    context "when quality does not exist" do
      it "returns not found error" do
        get "/api/v1/async/videos/qualities/999999", headers: auth_headers

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when unauthorized" do
      it "returns unauthorized without auth token" do
        get "/api/v1/async/videos/qualities/#{quality.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
