module Api
  module V1
    module Async
      class VideosController < ApiController
        def create
          @video = Video.create!(external_video_link: video_params[:external_video_link])

          transcoding_profile_labels = video_params[:transcoding_profile_labels] || []
          transcoding_profiles = transcoding_profile_labels.map do |label|
            ::Videos::TranscodingProfile.find_by!(label: label)
          end

          @video.create_transcoding_process!(transcoding_profiles)
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
