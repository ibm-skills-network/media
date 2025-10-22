module Api
  module V1
    module Async
      module Videos
        class QualitiesController < ApiController
          before_action :set_quality, only: [ :show ]

          def create
            @video = Video.create!(video_params)
            @qualities = @video.create_qualities!
            render status: :created
          end

          def show
          end

          private

          def video_params
            params.permit(:external_video_link)
          end

          def set_quality
            @quality = ::Videos::Quality.includes(:video, :transcoding_profile).find(params[:id])
          end
        end
      end
    end
  end
end
