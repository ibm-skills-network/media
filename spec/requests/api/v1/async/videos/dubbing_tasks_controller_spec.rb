require "rails_helper"

RSpec.describe Api::V1::Async::Videos::DubbingTasksController, type: :controller do
  include_context "admin"

  describe "GET #show" do
    let(:task) { create(:dubbing_task, status: "processing") }

    it "returns ok" do
      get :show, params: { id: task.id }
      expect(response).to have_http_status(:ok)
    end

    it "returns status and error_message" do
      task.update!(status: "failed", error_message: "boom")

      get :show, params: { id: task.id }

      json = JSON.parse(response.body)
      expect(json).to include("status" => "failed", "error_message" => "boom")
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        dubbing_task: {
          video_url: "https://example.com/video.mp4",
          language: "Spanish",
          dialect: "latin-american"
        }
      }
    end

    it "creates a DubbingTask" do
      expect {
        post :create, params: valid_params
      }.to change(DubbingTask, :count).by(1)
    end

    it "enqueues ExtractAudioJob with the task id" do
      expect {
        post :create, params: valid_params
      }.to have_enqueued_job(DubbingPipeline::ExtractAudioJob).with(kind_of(Integer))
    end

    it "returns created with the task id and status" do
      post :create, params: valid_params

      json = JSON.parse(response.body)
      expect(response).to have_http_status(:created)
      expect(json).to include("id", "status" => "pending")
    end

    context "when validation fails" do
      it "returns 422 with errors and does not enqueue a job" do
        bad_params = valid_params.deep_merge(dubbing_task: { language: "Klingon" })

        expect {
          post :create, params: bad_params
        }.not_to have_enqueued_job(DubbingPipeline::ExtractAudioJob)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to have_key("errors")
      end
    end
  end
end
