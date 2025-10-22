module Videos
  class Quality
    class TranscodingProfile < ApplicationRecord
      self.table_name = "videos_qualities_transcoding_profiles"

      has_many :qualities, class_name: "Videos::Quality", foreign_key: "transcoding_profile_id", dependent: :restrict_with_error

      enum :label, { "480p" => 0, "720p" => 1, "1080p" => 2 }
    end
  end
end
