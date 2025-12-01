module Videos
  module Quality
    class TranscodingProcess < ApplicationRecord
      self.table_name = "videos_qualities_transcoding_processes"

      has_one_attached :video_file
      belongs_to :video
      belongs_to :transcoding_profile, class_name: "Videos::Quality::TranscodingProfile"

      delegate :label, to: :transcoding_profile

      enum :status, { pending: 0, processing: 1, success: 2, failed: 3, unavailable: 4 }, default: :pending

      before_create :validate_video_quality

      def self.determine_max_quality(url)
        metadata = Ffmpeg::Video.video_metadata_from_url(url)

        video_stream = metadata["streams"].find { |stream| stream["width"].present? && stream["height"].present? }

        width = video_stream["width"]
        height = video_stream["height"]

        if height >= 1080 && width >= 1920
          "1080p"
        elsif height >= 720 && width >= 1280
          "720p"
        else
          "480p"
        end
      end

      private

      def validate_video_quality
        return unless video&.external_video_link.present?

        max_quality = self.class.determine_max_quality(video.external_video_link)
        max_quality_value = Videos::Quality::TranscodingProfile.labels[max_quality]
        target_quality_value = Videos::Quality::TranscodingProfile.labels[transcoding_profile.label]

        if max_quality_value < target_quality_value
          self.status = :unavailable
        end
      end
    end
  end
end
