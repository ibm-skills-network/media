module Api
  module V1
    module Async
      module Videos
        class QualitiesController < ApiController
          before_action :set_quality, only: [ :show ]

          def show
            render json: {
              status: @quality.status,
              url: @quality.video_file&.url,
              label: @quality.transcoding_profile.label
            }, status: :ok
          end

          private

          def set_quality
            @quality = ::Videos::Quality.includes(:transcoding_profile).find(params[:id])
          end
        end
      end
    end
  end
end
