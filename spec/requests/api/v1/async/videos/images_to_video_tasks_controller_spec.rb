require "rails_helper"

RSpec.describe Api::V1::Async::Videos::ImagesToVideoTasksController, type: :controller do
  include_context "admin"

  describe "POST #create" do
    let(:task_params) do
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

    it "creates an ImagesToVideoTask with pending status" do
      expect {
        post :create, params: task_params
      }.to change(Videos::ImagesToVideoTask, :count).by(1)

      expect(Videos::ImagesToVideoTask.last.status).to eq("pending")
    end

    it "enqueues ImagesToVideoJob" do
      expect {
        post :create, params: task_params
      }.to have_enqueued_job(Videos::ImagesToVideoJob)
    end

    it "returns created status" do
      post :create, params: task_params

      expect(response).to have_http_status(:created)
    end

    it "returns task id and status" do
      post :create, params: task_params

      json_response = JSON.parse(response.body)
      expect(json_response["images_to_video_task"]).to include("id", "status")
      expect(json_response["images_to_video_task"]["status"]).to eq("pending")
    end

    context "with presigned_url" do
      let(:task_params_with_presigned) do
        task_params.merge(presigned_url: "https://example.com/presigned")
      end

      it "passes presigned_url to the job" do
        post :create, params: task_params_with_presigned

        expect(Videos::ImagesToVideoJob).to have_been_enqueued.with(
          anything,
          anything,
          presigned_url: "https://example.com/presigned"
        )
      end
    end
  end
end
