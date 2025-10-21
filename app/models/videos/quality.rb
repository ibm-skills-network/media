module Videos
  class Quality < ApplicationRecord
    self.table_name_prefix = "videos_"

    belongs_to :video, class_name: "Video"
    has_one_attached :video_file
    has_one :transcoding_profile, class_name: "Videos::Quality::TranscodingProfile", foreign_key: "video_quality_id", dependent: :destroy

    delegate :label, to: :transcoding_profile

    enum :status, { pending: 0, processing: 1, success: 2, failed: 3, unavailable: 4 }, default: :pending


    def encode_video
      processing!
      EncodeQualityJob.perform_now(self.id)
    end

    def encode_video_later
      pending!
      EncodeQualityJob.perform_later(self.id)
    end
  end
end
