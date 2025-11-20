module Api
  module V1
    module Async
      module Videos
        class QualitiesController < ApiController
          before_action :set_quality, only: [ :show ]

          def create
            transcoding_profile = ::Videos::Quality::TranscodingProfile.find_by!(label: quality_params[:transcoding_profile_label])

            @quality = ::Videos::Quality.new(
              external_video_link: quality_params[:external_video_link],
              transcoding_profile: transcoding_profile
            )
            @quality.save!
            @quality.encode_video_later

            render json: {
              id: @quality.id,
              label: @quality.label,
              status: @quality.status
            }, status: :created
          end

          def show
          end

          private

          def quality_params
            params.permit(:external_video_link, :transcoding_profile_label)
          end

          def set_quality
            @quality = ::Videos::Quality.includes(:transcoding_profile).find(params[:id])
          end
        end
      end
    end
  end
end
