module Videos
  class TranscodeVideoJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
      video = Video.find(msg["args"].first)
      video.transcoding_processes.each { |tp| tp.failed! unless tp.success? || tp.unavailable? } if video.present?
    end

    def perform(video_id)
      video = Video.includes(transcoding_processes: :transcoding_profile).find(video_id)

      return if video.transcoding_processes.all? { |tp| tp.success? || tp.unavailable? }

      video.transcode_video!
    end
  end
end
