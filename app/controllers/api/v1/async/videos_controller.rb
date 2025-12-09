module Api
  module V1
    module Async
      class VideosController < ApiController
        def show
          @video = Video.includes(:transcoding_processes).find(params[:id])

          render json: {
            id: @video.id,
            external_video_link: @video.external_video_link,
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
          @video = Video.create!(external_video_link: video_params[:external_video_link])

          transcoding_profile_labels = video_params[:transcoding_profile_labels]
          ::Videos::TranscodingProcess.create_transcoding_processes!(@video, transcoding_profile_labels)
          ::Videos::TranscodeVideoJob.perform_later(@video.id)
          render json: {
            transcoding_processes: @video.transcoding_processes.map do |transcoding_process|
              {
                id: transcoding_process.id,
                label: transcoding_process.label,
                status: transcoding_process.status
              }
            end
          }, status: :created
        end

        private

        def video_params
          params.permit(:external_video_link, transcoding_profile_labels: [])
        end
      end
    end
  end
end
