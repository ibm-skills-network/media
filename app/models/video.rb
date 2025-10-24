class Video < ApplicationRecord
  has_many :qualities, class_name: "Videos::Quality", dependent: :destroy

  before_create :validate_external_video_link

  VIDEO_TYPES = [ "video/mp4", "video/webm", "video/quicktime" ].freeze

  def self.determine_max_quality(file_path)
    metadata = Ffmpeg::Video.video_metadata(file_path)

    video_stream = metadata["streams"].find { |stream| stream["width"].present? && stream["height"].present? }

    width = video_stream["width"]
    height = video_stream["height"]
    bitrate = video_stream["bit_rate"].to_i

    if height >= 1080 && width >= 1920 && bitrate >= 2_000_000 # 2 Mbps
      "1080p"
    elsif height >= 720 && width >= 1280 && bitrate >= 1_000_000 # 1 Mbps
      "720p"
    else
      "480p"
    end
  end

  def create_qualities!
    qualities = []
    Setting::TRANSCODING_PROFILES.each do |transcoding_profile|
      q = self.qualities.build(transcoding_profile: transcoding_profile)
      q.encode_video_later
      qualities << q
    end
    qualities
  end

  def download_to_file
    extension = case Ffmpeg::Video.mime_type(external_video_link)
    when "video/mp4"
      ".mp4"
    when "video/webm"
      ".webm"
    when "video/quicktime"
      ".mov"
    else
      return nil
    end

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

  private

  def validate_external_video_link
    unless VIDEO_TYPES.include?(Ffmpeg::Video.mime_type(external_video_link))
      errors.add(:external_video_link, "must be a valid video file (mp4, webm, or mov)")
    end
  end
end
