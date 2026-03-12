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
            profile = if task_params[:codec]
              ::Videos::ImagesToVideoProfile.find_by!(codec: task_params[:codec])
            else
              ::Videos::ImagesToVideoProfile.find_by!(codec: Setting::DEFAULT_IMAGE_TO_TASK_PROFILE_CODEC)
            end
            @task = ::Videos::ImagesToVideoTask.create!(images_to_video_profile: profile)

            queue = profile.gpu? ? :gpu : :critical
            ::Videos::ImagesToVideoJob.set(queue: queue).perform_later(@task.id, task_params[:chunks].map(&:to_h), task_params[:width].to_i, task_params[:height].to_i)

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
            params.permit(:codec, :width, :height, chunks: [ :image_url, :audio_url ])
          end
        end
      end
    end
  end
end
