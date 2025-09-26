class VideosController < ApplicationController
  def create
    video = Video.new(video_params)

    if video.save
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
    videos = Video.all
    render json: videos.map { |video|
      {
        id: video.id,
        title: video.title,
        created_at: video.created_at,
        has_video_file: video.video_file.attached?
      }
    }
  end

  def show
    video = Video.find(params[:id])
    render json: {
      id: video.id,
      title: video.title,
      created_at: video.created_at,
      has_video_file: video.video_file.attached?,
      video_file_url: video.video_file.attached? ? url_for(video.video_file) : nil
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Video not found" }, status: :not_found
  end

  private

  def video_params
    params.permit(:title, :video_file)
  end
end
