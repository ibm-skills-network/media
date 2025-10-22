class Video < ApplicationRecord
  has_many :qualities, class_name: "Videos::Quality", dependent: :destroy

  before_create :validate_external_video_link

  VIDEO_TYPES = [ "video/mp4", "video/webm", "video/quicktime" ].freeze

  def create_qualities!(video_params)
    Setting::TRANSCODING_PROFILES.each do |transcoding_profile|
      q = qualities.create!(transcoding_profile: transcoding_profile)
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
