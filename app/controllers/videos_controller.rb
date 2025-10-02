class VideosController < ApplicationController
  before_action :set_video, only: [ :show, :poll ]
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
    render json: {
      title: @video.title,
      description: @video.description,
      external_video_link: @video.external_video_link,
      qualities: @video.qualities.map { |q| {
        quality: q.quality,
        status: q.status,
        video_file: q.video_file&.url
      } }
    }
  end

  def poll
    if @video.qualities.all? { |q| q.completed? || q.unavailable? || q.failed? }
      render json: {
        status: "completed"
      }
    else
      render json: {
        status: "processing"
      }
    end
  end



  private

  def video_params
    params.permit(:title, :description, :external_video_link)
  end

  def set_video
    @video = Video.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "Video not found"
    }, status: :not_found
  end
end
