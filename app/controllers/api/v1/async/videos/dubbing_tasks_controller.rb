module Api
  module V1
    module Async
      module Videos
        class DubbingTasksController < ApiController
          before_action :set_dubbing_task, only: %w[show]

          def show
            render json: {
              status: @dubbing_task.status,
              error_message: @dubbing_task.error_message
            }, status: :ok
          end

          def create
            task = DubbingTask.new(dubbing_params)
            if task.save
              DubbingPipeline::ExtractAudioJob.perform_later(task.id)
              render json: { id: task.id, status: task.status }, status: :created
            else
              render json: { errors: task.errors }, status: :unprocessable_entity
            end
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
