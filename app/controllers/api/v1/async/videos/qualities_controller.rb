module Api
  module V1
    module Async
      module Videos
        class QualitiesController < ApiController
          before_action :set_video, only: [ :show ]

          def create
            @video = Video.create!(video_params)
            @video.create_qualities!

            render status: :created
          end

          def show
          end

          private

          def video_params
            params.permit(:external_video_link)
          end

          def set_video
            @video = Video.includes(qualities: :transcoding_profile).find(params[:id])
          end
        end
      end
    end
  end
end
