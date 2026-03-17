module Videos
  class ImagesToVideoProfile < ApplicationRecord
    self.table_name = "videos_images_to_video_profiles"

    has_many :images_to_video_tasks,
      class_name: "Videos::ImagesToVideoTask",
      foreign_key: "images_to_video_profile_id",
      dependent: :restrict_with_error
  end
end
