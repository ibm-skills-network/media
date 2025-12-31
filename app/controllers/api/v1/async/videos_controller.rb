module Api
  module V1
    module Async
      class VideosController < ApiController
        before_action :set_video, only: %w[ show destroy ]
        def show
          @video = Video.includes(:transcoding_processes).find(params[:id])

          render json: {
            id: @video.id,
            external_video_link: @video.external_video_link,
            status: @video.status,
            transcoding_processes: @video.transcoding_processes.map do |transcoding_process|
              {
                id: transcoding_process.id,
                label: transcoding_process.label,
                status: transcoding_process.status
              }
            end
          }, status: :ok
        end

        def create
          if video_params[:video_file].present?
            @video = Video.create!
            @video.video_file.attach(video_params[:video_file])
          else
            @video = Video.create!(external_video_link: video_params[:external_video_link])
          end

          @video.success!

          transcoding_profile_labels = video_params[:transcoding_profile_labels]
          ::Videos::TranscodingProcess.create_transcoding_processes!(@video, transcoding_profile_labels)
          ::Videos::TranscodeVideoJob.perform_later(@video.id)
          render json: {
            status: @video.status,
            transcoding_processes: @video.transcoding_processes.map do |transcoding_process|
              {
                id: transcoding_process.id,
                label: transcoding_process.label,
                status: transcoding_process.status
              }
            end
          }, status: :created
        end

        def destroy
          @video = Video.find(params[:id])
          @video.destroy!
          render json: { message: "Video destroyed" }, status: :ok
        end

        private

        def video_params
          params.permit(:external_video_link, :video_file, transcoding_profile_labels: [])
        end
      end
    end
  end
end
