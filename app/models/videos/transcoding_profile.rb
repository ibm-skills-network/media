module Videos
  class TranscodingProfile < ApplicationRecord
    self.table_name = "videos_qualities_transcoding_profiles"

    has_many :transcoding_tasks, class_name: "Videos::TranscodingTask", foreign_key: "transcoding_profile_id", dependent: :restrict_with_error

    enum :label, { "480p" => 0, "720p" => 1, "1080p" => 2 }
  end
end
