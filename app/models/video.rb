class Video < ApplicationRecord
  has_one_attached :video_file
  has_many :videos_qualities, class_name: "Videos::Quality"

  def enqueue_quality_conversion(quality:)
    Videos::CreateQualityJob.perform_later(
      video_id: id,
      quality: quality
    )
  end
end
