module Api
  module V1
    module Async
      module Videos
        class TranscodingProcessesController < ApiController
          before_action :set_transcoding_process, only: %w[ show destroy ]

          def show
            render json: {
              status: @transcoding_process.status,
              url: @transcoding_process.video_file&.url,
              label: @transcoding_process.transcoding_profile.label
            }, status: :ok
          end

          def destroy
            @transcoding_process.destroy!
            render json: { message: "Transcoding process deleted" }, status: :ok
          end

          private

          def set_transcoding_process
            @transcoding_process = ::Videos::TranscodingProcess.includes(:transcoding_profile).find(params[:id])
          end
        end
      end
    end
  end
end
