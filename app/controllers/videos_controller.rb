class VideosController < ApplicationController
  def create
    video = Video.new(video_params)

    if video.save
      video.create_qualities(video_params)
      render json: {
        id: video.id,
        message: "Video uploaded successfully",
        status: "success"
      }, status: :created
    else
      render json: {
        errors: video.errors.full_messages,
        status: "error"
      }, status: :unprocessable_entity
    end
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
