module Api
  module V1
    module Async
      module Videos
        class ImagesToVideoTasksController < ApiController
          def show
            @task = ::Videos::ImagesToVideoTask.find(params[:id])

            render json: {
              id: @task.id,
              status: @task.status,
              video_file_url: @task.video_file.url
            }, status: :ok
          end
          def create
            @task = ::Videos::ImagesToVideoTask.create!

            ::Videos::ImagesToVideoJob.perform_later(@task.id, task_params[:chunks].map(&:to_h))

            render json: {
                id: @task.id,
                status: @task.status
            }, status: :created
          end

          private

          def task_params
            params.permit(chunks: [ :image_url, :audio_url ])
          end
        end
      end
    end
  end
end
