module Api
  module V1
    module Async
      module Videos
        class TranscodingTasksController < ApiController
          before_action :set_transcoding_task, only: %w[ show ]

          def show
            render json: {
              status: @transcoding_task.status,
              url: @transcoding_task.video_file&.url,
              label: @transcoding_task.transcoding_profile.label
            }, status: :ok
          end

          def create
            if video_params[:video_file].present?
              @video = Video.new
              @video.video_file.attach(video_params[:video_file])
            else
              @video = Video.new(external_video_link: video_params[:external_video_link])
            end

            unless @video.save
              render json: { error: @video.errors.full_messages.join(", ") }, status: :unprocessable_entity and return
            end

            transcoding_profile_labels = video_params[:transcoding_profile_labels]
            ::Videos::TranscodingTask.create_transcoding_tasks!(@video, transcoding_profile_labels)
            ::Videos::TranscodeVideoJob.perform_later(@video.id)
            render json: {
              transcoding_tasks: @video.transcoding_tasks.map do |transcoding_task|
                {
                  id: transcoding_task.id,
                  label: transcoding_task.label,
                  status: transcoding_task.status
                }
              end
            }, status: :created
          end

          private

          def set_transcoding_task
            @transcoding_task = ::Videos::TranscodingTask.includes(:transcoding_profile).find(params[:id])
          end

          def video_params
            params.permit(:id, :external_video_link, :video_file, transcoding_profile_labels: [])
          end
        end
      end
    end
  end
end
