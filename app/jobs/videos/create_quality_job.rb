module Videos
  class CreateQualityJob < ApplicationJob
    queue_as :default

    def perform(video_id:, quality:)
      video = Video.find(video_id)

      Videos::QualityService.encode_quality(video, quality)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error("Video not found: #{e.message}")
      raise
    rescue StandardError => e
      Rails.logger.error("Failed to create #{quality} quality for video #{video_id}: #{e.message}")

      # Create a failed quality record
      Videos::Quality.create!(
        video_id: video_id,
        quality: quality,
        status: "failed"
      )

      raise
    end
  end
end
