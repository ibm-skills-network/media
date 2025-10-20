module Videos
  class EncodeQualityJob < ApplicationJob
  queue_as :gpu



    # after sidekiq retries -> fail it
    def perform(quality_id)
      quality = Videos::Quality.includes(:video).find(quality_id)
      video = quality.video

      return if quality.completed?

      case Ffmpeg::Video.mime_type(video.external_video_link)
      when "video/mp4"
          temp_input = Tempfile.new([ "#{video.id}_input", ".mp4" ])
      when "video/webm"
          temp_input = Tempfile.new([ "#{video.id}_input", ".webm" ])
      when "video/quicktime"
          temp_input = Tempfile.new([ "#{video.id}_input", ".mov" ])
      else
          quality.unavailable!
          return
      end

      temp_output = Tempfile.new([ "#{video.id}_output", ".mp4" ])

      temp_input.binmode
      Faraday.get(video.external_video_link) do |req|
        req.options.on_data = Proc.new do |chunk, overall_received_bytes|
          temp_input.write(chunk)
        end
      end
      temp_input.close

      if Videos::Quality.qualities[Ffmpeg::Video.determine_max_quality(temp_input.path)] < Videos::Quality.qualities[quality.quality]
        quality.unavailable!
        return
      end

      temp_output.close

      Rails.logger.info "Input file size: #{File.size(temp_input.path)} bytes"

      result = Ffmpeg::Video.encode_video(temp_input.path, temp_output.path, quality.quality)

      Rails.logger.info "Encode result: #{result.inspect}"
      Rails.logger.info "Output file size: #{File.size(temp_output.path)} bytes"
      Rails.logger.info "Output file exists: #{File.exist?(temp_output.path)}"

      if result[:success]
        File.open(temp_output.path, "rb") do |file|
          Rails.logger.info "File size being attached: #{file.size} bytes"
          quality.video_file.attach(io: file, filename: "#{video.id}_output.mp4")
        end
        quality.status(:success)
        quality.transcoding_log.create(codec: result[:codec], label: result[:label])
        quality.save!
      else
        raise result[:error]
      end
    ensure
      temp_input&.unlink
      temp_output&.unlink
    end
  end
end
