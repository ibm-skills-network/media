module Api
  module V1
    module Async
      module Videos
        module Qualities
          class TranscodingProcessesController < ApiController
            before_action :set_transcoding_process, only: [ :show ]

            def show
              render json: {
                status: @transcoding_process.status,
                url: @transcoding_process.video_file&.url,
                label: @transcoding_process.transcoding_profile.label
              }, status: :ok
            end

            private

            def set_transcoding_process
              @transcoding_process = ::Videos::Quality::TranscodingProcess.includes(:transcoding_profile).find(params[:id])
            end
          end
        end
      end
    end
  end
end
