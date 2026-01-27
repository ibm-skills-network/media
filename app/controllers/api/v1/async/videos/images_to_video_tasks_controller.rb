module Api
  module V1
    module Async
      module Videos
        class ImagesToVideoTasksController < ApiController
            before_action :set_task, only: %w[ show ]

          def show
            render json: {
              id: @task.id,
              status: @task.status,
              video_file_url: @task.video_file.url
            }, status: :ok
          end

          def create
            @task = ::Videos::ImagesToVideoTask.create!

            width = task_params[:width]&.to_i || 1280
            height = task_params[:height]&.to_i || 720

            ::Videos::ImagesToVideoJob.perform_later(@task.id, task_params[:chunks].map(&:to_h), width, height)

            render json: {
                id: @task.id,
                status: @task.status
            }, status: :created
          end

          private

          def set_task
            @task = ::Videos::ImagesToVideoTask.find(params[:id])
          end

          def task_params
            params.permit(:width, :height, chunks: [ :image_url, :audio_url ])
          end
        end
      end
    end
  end
end
