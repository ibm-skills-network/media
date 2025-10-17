module Api
  module V1
    class VideosController < ApiController
      before_action :set_video, only: [ :show ]
      def create
        video = Video.create!(video_params)
        video.create_qualities!(video_params)

        render json: {
          id: video.id,
          message: "Video uploaded successfully",
          status: "success"
        }, status: :created
      end

      def show
        render json: {
          external_video_link: @video.external_video_link,
          qualities: @video.qualities.to_h { |q| [ q.quality, {
            status: q.status,
            url: q.video_file&.url
          } ] }
        }
      end

      private

      def video_params
        params.permit(:external_video_link)
      end

      def set_video
        @video = Video.includes(:qualities).find(params[:id])
      end
    end
  end
end
