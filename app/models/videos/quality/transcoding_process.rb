module Videos
  module Quality
    class TranscodingProcess < ApplicationRecord
      self.table_name = "videos_qualities_transcoding_processes"

      has_one_attached :video_file
      belongs_to :transcoding_profile, class_name: "Videos::Quality::TranscodingProfile"

      delegate :label, to: :transcoding_profile

      enum :status, { pending: 0, processing: 1, success: 2, failed: 3, unavailable: 4 }, default: :pending

      before_create :validate_external_video_link

      VIDEO_TYPES = [ "video/mp4", "video/webm", "video/quicktime" ].freeze

      def self.determine_max_quality(file_path)
        metadata = Ffmpeg::Video.video_metadata(file_path)

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

      def validate_external_video_link
        unless VIDEO_TYPES.include?(Ffmpeg::Video.mime_type(external_video_link))
          errors.add(:external_video_link, "must be a valid video file (mp4, webm, or mov)")
        end
      end
    end
  end
end
