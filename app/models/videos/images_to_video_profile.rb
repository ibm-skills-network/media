module Videos
  class ImagesToVideoProfile < ApplicationRecord
    self.table_name = "videos_images_to_video_profiles"

    has_many :images_to_video_tasks,
      class_name: "Videos::ImagesToVideoTask",
      foreign_key: "images_to_video_profile_id",
      dependent: :restrict_with_error

    enum :label, { "vp9" => 0, "av1_nvenc" => 1, "openh264" => 2 }
  end
end
