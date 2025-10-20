module Api
  module V1
    module Async
      module Videos
        class QualitiesController < ApiController
          before_action :set_video, only: [ :show ]
          rate_limit to: 100, within: 1.hour, by: -> { request.remote_ip }, only: :create

          def create
            @video = Video.create!(video_params)
            @video.create_qualities!(video_params)

            render status: :created
          end

          def show
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
