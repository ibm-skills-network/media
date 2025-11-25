module Videos
  class Quality < ApplicationRecord
    self.table_name_prefix = "videos_"

    has_one_attached :video_file
    belongs_to :video, class_name: "Video"
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

    def self.create_qualities_for_video!(external_video_link)
      qualities = []
      Setting::TRANSCODING_PROFILES.each do |transcoding_profile|
        q = Videos::Quality.new(
          external_video_link: external_video_link,
          transcoding_profile: transcoding_profile
        )
        q.save!
        q.encode_video_later
        qualities << q
      end
      qualities
    end

    def download_to_file
      mime_type = Ffmpeg::Video.mime_type(external_video_link)

      extension = case mime_type
      when "video/mp4"
        ".mp4"
      when "video/webm"
        ".webm"
      when "video/quicktime"
        ".mov"
      else
        extract_extension_from_url(external_video_link)
      end

      return nil unless extension.present?

      temp_file = Tempfile.new([ "#{id}_input", extension ])
      temp_file.binmode

      Faraday.get(external_video_link) do |req|
        req.options.on_data = Proc.new do |chunk, overall_received_bytes|
          temp_file.write(chunk)
        end
      end
      temp_file.close

      temp_file
    end

    def encode_video
      EncodeQualityJob.perform_now(self.id)
    end

    def encode_video_later
      pending!
      EncodeQualityJob.perform_later(self.id)
    end

    private

    def extract_extension_from_url(url)
      uri = URI.parse(url)
      path = uri.path

      # Extract the file extension
      ext = File.extname(path).downcase

      case ext
      when ".mp4", ".webm", ".mov"
        ext
      else
        nil
      end
    rescue URI::InvalidURIError
      nil
    end

    def validate_external_video_link
      unless VIDEO_TYPES.include?(Ffmpeg::Video.mime_type(external_video_link))
        errors.add(:external_video_link, "must be a valid video file (mp4, webm, or mov)")
      end
    end
  end
end
