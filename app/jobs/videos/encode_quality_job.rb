module Videos
  class EncodeQualityJob < ApplicationJob
    queue_as :gpu



    # after sidekiq retries -> fail it
    def perform(quality_id)
      quality = Videos::Quality.includes(:video, :transcoding_profile).find(quality_id)
      video = quality.video

      return if quality.success?

      quality.with_lock do
        raise "Quality already processing" if quality.processing?

        quality.processing!
      end

      temp_input = video.download_to_file
      unless temp_input
        quality.unavailable!
        return
      end

      max_quality_label = Video.determine_max_quality(temp_input.path)
      if Videos::Quality::TranscodingProfile.labels[max_quality_label] < Videos::Quality::TranscodingProfile.labels[quality.transcoding_profile.label]
        quality.unavailable!
        return
      end

      temp_output = Tempfile.new([ "#{video.id}_output", ".mp4" ])

      temp_output.close

      Rails.logger.info "Input file size: #{File.size(temp_input.path)} bytes"

      result = Ffmpeg::Video.encode_video(
        temp_input.path,
        temp_output.path,
        quality.transcoding_profile
      )

      Rails.logger.info "Encode result: #{result.inspect}"
      Rails.logger.info "Output file size: #{File.size(temp_output.path)} bytes"
      Rails.logger.info "Output file exists: #{File.exist?(temp_output.path)}"

      if result[:success]
        File.open(temp_output.path, "rb") do |file|
          Rails.logger.info "File size being attached: #{file.size} bytes"
          quality.video_file.attach(io: file, filename: "#{video.id}_output.mp4")
        end
        quality.success!
      else
        raise result[:error]
      end
    ensure
      if quality.processing?
        quality.pending!
      end
      temp_input&.unlink
      temp_output&.unlink
    end
  end
end
