module Api
  module V1
    module Async
      class VideosController < ApiController
        def create
          @video = Video.create!(external_video_link: video_params[:external_video_link])

          transcoding_profile_labels = video_params[:transcoding_profile_labels] || []
          transcoding_profiles = transcoding_profile_labels.map do |label|
            ::Videos::Quality::TranscodingProfile.find_by!(label: label)
          end

          @video.create_qualities!(transcoding_profiles)
          ::Videos::EncodeQualitiesJob.perform_later(@video.id)
          render json: {
            qualities: @video.qualities.map do |quality|
              {
                id: quality.id,
                label: quality.label,
                status: quality.status
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
