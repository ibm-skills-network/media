require "rails_helper"

RSpec.describe Api::V1::Async::Videos::ImagesToVideoTasksController, type: :controller do
  include_context "admin"

  let(:profile) { create(:images_to_video_profile) }
  let(:chunks) do
    [
      { image_url: "https://example.com/image1.png", audio_url: "https://example.com/audio1.mp3" },
      { image_url: "https://example.com/image2.png", audio_url: "https://example.com/audio2.mp3" }
    ]
  end

  describe "POST #create" do
    let(:task_params) do
      { codec: profile.codec, width: 1280, height: 720, chunks: chunks }
    end

    it "creates an ImagesToVideoTask with pending status" do
      expect {
        post :create, params: task_params
      }.to change(Videos::ImagesToVideoTask, :count).by(1)

      expect(Videos::ImagesToVideoTask.last.status).to eq("pending")
    end

    it "associates the task with the correct profile" do
      post :create, params: task_params

      expect(Videos::ImagesToVideoTask.last.images_to_video_profile).to eq(profile)
    end

    it "enqueues ImagesToVideoJob with correct arguments" do
      post :create, params: task_params

      task = Videos::ImagesToVideoTask.last
      expect(Videos::ImagesToVideoJob).to have_been_enqueued.with(task.id, chunks.map(&:stringify_keys), 1280, 720)
    end

    it "returns created status" do
      post :create, params: task_params

      expect(response).to have_http_status(:created)
    end

    it "returns task id and status" do
      post :create, params: task_params

      json_response = JSON.parse(response.body)
      expect(json_response).to include("id", "status")
      expect(json_response["status"]).to eq("pending")
    end

    context "when codec is not provided" do
      let(:default_profile) { create(:images_to_video_profile, :av1_nvenc) }

      before { default_profile }

      it "uses the default profile codec" do
        post :create, params: { width: 1280, height: 720, chunks: chunks }

        expect(Videos::ImagesToVideoTask.last.images_to_video_profile).to eq(default_profile)
      end
    end

    context "when codec does not match any profile" do
      it "returns not found" do
        post :create, params: task_params.merge(codec: "nonexistent_codec")

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET #show" do
    let(:task) { create(:images_to_video_task) }

    it "returns the task" do
      get :show, params: { id: task.id }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["id"]).to eq(task.id)
      expect(json_response["status"]).to eq(task.status)
    end

    context "when task does not exist" do
      it "returns not found" do
        get :show, params: { id: 0 }

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
