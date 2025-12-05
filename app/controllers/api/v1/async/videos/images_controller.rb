module Api
  module V1
    module Async
      module Videos
        class ImagesController < ApiController
          def create
            @video = Video.create!(external_video_link: nil)

            chunks = params[:chunks].map do |chunk|
              {
                "image_url" => chunk[:image_url],
                "audio_url" => chunk[:audio_url]
              }
            end

            ::Videos::CreateFromImagesJob.perform_later(@video.id, chunks)

            render json: {
              video: {
                id: @video.id,
                status: "processing"
              }
            }, status: :created
          end

          private

          def video_params
            params.permit(chunks: [ :image_url, :audio_url ])
          end
        end
      end
    end
  end
end
