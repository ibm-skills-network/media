module Api
  module V1
    module Async
      module Videos
        class QualitiesController < ApiController
          before_action :set_video, only: [ :show ]
          def create
            @video = Video.create!(video_params)
            @video.create_qualities!(video_params)

            render json: (Jbuilder.encode do |json|
              json.id @video.id
              json.message "Video uploaded successfully"
              json.status "success"
            end), status: :created
          end

          def show
            render json: (Jbuilder.encode do |json|
              json.external_video_link @video.external_video_link
              json.qualities do
                @video.qualities.each do |q|
                  json.set! q.quality do
                    json.status q.status
                    json.url q.video_file&.url
                  end
                end
              end
            end)
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
  end
end
