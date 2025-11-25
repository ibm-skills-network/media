module Videos
  class EncodeQualitiesJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
      video = Video.find(msg["args"].first)
      video.qualities.each { |q| q.failed! unless q.success? || q.unavailable? } if video.present?
    end

    def perform(video_id)
      video = Video.includes(qualities: :transcoding_profile).find(video_id)

      return if video.qualities.all? { |q| q.success? || q.unavailable? }

      video.encode_qualities!
    end
  end
end
