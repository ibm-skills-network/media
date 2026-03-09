module Videos
  class ImagesToVideoTask < ApplicationRecord
    has_one_attached :video_file

    belongs_to :images_to_video_profile, class_name: "Videos::ImagesToVideoProfile"

    enum :status, { pending: "pending", processing: "processing", success: "success", failed: "failed" }, default: "pending"
  end
end
