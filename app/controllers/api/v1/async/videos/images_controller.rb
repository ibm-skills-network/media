module Api
  module V1
    module Async
      module Videos
        class ImagesController < ApiController
          def create
            @video = Video.create!(external_video_link: nil)

            ::Videos::CreateFromImagesJob.perform_later(@video.id, video_params[:chunks].map(&:to_h), presigned_url: video_params[:presigned_url])

            render json: {
              video: {
                id: @video.id,
                status: "processing"
              }
            }, status: :created
          end

          private

          def video_params
            params.permit(chunks: [ :image_url, :audio_url ], presigned_url:)
          end
        end
      end
    end
  end
end
