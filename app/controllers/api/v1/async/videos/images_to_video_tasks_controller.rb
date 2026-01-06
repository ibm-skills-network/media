module Api
  module V1
    module Async
      module Videos
        class ImagesToVideoTasksController < ApiController
          def create
            @video = Video.create!(external_video_link: nil, status: "pending")

            ::Videos::ImagesToVideoJob.perform_later(@video.id, video_params[:chunks].map(&:to_h), presigned_url: video_params[:presigned_url])

            render json: {
              video: {
                id: @video.id,
                status: @video.status
              }
            }, status: :created
          end

          private

          def video_params
            params.permit(:presigned_url, chunks: [ :image_url, :audio_url ])
          end
        end
      end
    end
  end
end
