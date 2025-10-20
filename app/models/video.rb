class Video < ApplicationRecord
  has_many :qualities, class_name: "Videos::Quality", dependent: :destroy

  before_create :validate_external_video_link

  VIDEO_TYPES = [ "video/mp4", "video/webm", "video/quicktime" ].freeze

  def create_qualities!(video_params)
    Videos::Quality::TranscodingProfile.labels.keys.each do |label|
      transcoding_profile_data = Videos::Quality::TranscodingProfile::TRANSCODING_PROFILES[label]

      # Build the quality with its associated transcoding profile
      q = qualities.build
      q.build_transcoding_profile(
        label: label,
        codec: transcoding_profile_data[:codec],
        width: transcoding_profile_data[:width],
        height: transcoding_profile_data[:height],
        bitrate_string: transcoding_profile_data[:bitrate],
        bitrate_int: transcoding_profile_data[:bitrate_int]
      )
      q.save!
      q.encode_video_later
    end
  end

  private

  def validate_external_video_link
    unless VIDEO_TYPES.include?(Ffmpeg::Video.mime_type(external_video_link))
      errors.add(:external_video_link, "must be a valid video file (mp4, webm, or mov)")
    end
  end
end
