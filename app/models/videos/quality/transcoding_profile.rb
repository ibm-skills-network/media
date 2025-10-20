module Videos
  class Quality
    class TranscodingProfile < ApplicationRecord
      self.table_name = "videos_qualities_transcoding_profiles"

      belongs_to :quality, class_name: "Videos::Quality"

      enum :label, { "480p" => 0, "720p" => 1, "1080p" => 2 }

      QUALITY_CONFIGS = {
        "1080p" => {
          width: 1920,
          height: 1080,
          bitrate: "2900k",
          bitrate_int: 2_900_000
        },
        "720p" => {
          width: 1280,
          height: 720,
          bitrate: "1800k",
          bitrate_int: 1_800_000
        },
        "480p" => {
          width: 854,
          height: 480,
          bitrate: "1000k",
          bitrate_int: 1_000_000
        }
      }.freeze
    end
  end
end
