require "rails_helper"

RSpec.describe Api::V1::Async::Videos::TranscodingTasksController, type: :controller do
  include_context "admin"
  include_context "ffmpeg video api"

  describe "GET #show" do
    let(:transcoding_profile) { create(:transcoding_profile, :p720) }
    let(:video) { create(:video, external_video_link: "https://example.com/video.mp4") }
    let(:transcoding_task) { create(:transcoding_task, video: video, transcoding_profile: transcoding_profile) }

    it "returns success status" do
      get :show, params: { id: transcoding_task.id }

      expect(response).to have_http_status(:ok)
    end

    it "returns transcoding task information" do
      get :show, params: { id: transcoding_task.id }

      json_response = JSON.parse(response.body)
      expect(json_response).to include(
        "status" => transcoding_task.status,
        "label" => transcoding_profile.label
      )
    end

    it "returns url when video file is attached" do
      get :show, params: { id: transcoding_task.id }

      json_response = JSON.parse(response.body)
      expect(json_response).to have_key("url")
    end
  end

  describe "POST #create" do
    let(:transcoding_profile) { create(:transcoding_profile, :p720) }
    let(:video_params) do
      {
        external_video_link: "https://example.com/video.mp4",
        transcoding_profile_labels: [ transcoding_profile.label ]
      }
    end

    it "creates a video" do
      expect {
        post :create, params: video_params
      }.to change(Video, :count).by(1)
    end

    it "creates transcoding tasks" do
      expect {
        post :create, params: video_params
      }.to change(Videos::TranscodingTask, :count).by(1)
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

    it "returns transcoding task information" do
      post :create, params: video_params

      json_response = JSON.parse(response.body)
      expect(json_response["transcoding_tasks"]).to be_an(Array)
      expect(json_response["transcoding_tasks"].first).to include(
        "id",
        "label",
        "status"
      )
    end
  end
end
