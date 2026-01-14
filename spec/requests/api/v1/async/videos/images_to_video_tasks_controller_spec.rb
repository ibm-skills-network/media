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
  end

  describe "GET #show" do
    let(:task) { Videos::ImagesToVideoTask.create! }


    it "returns the task" do
      get :show, params: { id: task.id }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["id"]).to eq(task.id)
      expect(json_response["status"]).to eq(task.status)
    end
  end
end
