module Api
  module V1
    module Async
      module Videos
        class DubbingTasksController < ApiController
          before_action :set_dubbing_task, only: %w[show]

          def show
            render json: {
              status: @dubbing_task.status,
              hls_path: @dubbing_task.hls_path,
              error_message: @dubbing_task.error_message
            }, status: :ok
          end

          def create
            task = DubbingTask.create!(dubbing_params)
            DubbingPipeline::ExtractAudioJob.perform_later(task.id)
            render json: { id: task.id, status: task.status }, status: :created
          end

          private

          def set_dubbing_task
            @dubbing_task = DubbingTask.find(params[:id])
          end

          def dubbing_params
            params.require(:dubbing_task).permit(:video_url, :language, :dialect)
          end
        end
      end
    end
  end
end
