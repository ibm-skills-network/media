class VideosController < ApplicationController
  def create
    video = Video.create!(video_params)
    video.create_qualities!(video_params)

    render json: {
      id: video.id,
      message: "Video uploaded successfully",
      status: "success"
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      errors: e.record.errors.full_messages,
      status: "error"
    }, status: :unprocessable_entity
  end

  def index
  end

  def show
  end


  private

  def video_params
    params.permit(:title, :description, :external_video_link)
  end
end
