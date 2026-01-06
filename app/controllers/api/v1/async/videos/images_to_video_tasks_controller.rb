module Api
  module V1
    module Async
      module Videos
        class ImagesToVideoTasksController < ApiController
          def create
            @task = ::Videos::ImagesToVideoTask.create!

            ::Videos::ImagesToVideoJob.perform_later(@task.id, task_params[:chunks].map(&:to_h), presigned_url: task_params[:presigned_url])

            render json: {
              images_to_video_task: {
                id: @task.id,
                status: @task.status
              }
            }, status: :created
          end

          private

          def task_params
            params.permit(:presigned_url, chunks: [ :image_url, :audio_url ])
          end
        end
      end
    end
  end
end
