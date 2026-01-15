module Videos
  class ImagesToVideoTask < ApplicationRecord
    has_one_attached :video_file

    enum :status, { pending: "pending", processing: "processing", success: "success", failed: "failed" }, default: "pending"
  end
end
