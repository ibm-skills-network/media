module Api
  module V1
    module Async
      class VideosController < ApiController
        def show
          @video = Video.includes(:transcoding_tasks).find(video_params[:id])

          render json: {
            id: @video.id,
            external_video_link: @video.external_video_link,
            status: @video.status,
            transcoding_tasks: @video.transcoding_tasks.map do |transcoding_task|
              {
                id: transcoding_task.id,
                label: transcoding_task.label,
                status: transcoding_task.status
              }
            end
          }, status: :ok
        end

        private

        def video_params
          params.permit(:id)
        end
      end
    end
  end
end
