module Videos
  class EncodeQualityJob < ApplicationJob
  queue_as :default



    # after sidekiq retries -> fail it
    def perform(quality_id)
    quality = Videos::Quality.includes(:video).find(quality_id)
    video = quality.video

    return if quality.completed?


    begin
      case Ffmpeg::Video.mime_type(video.external_video_link)[:mime_type]
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
      response = Faraday.get(video.external_video_link)
      temp_input.write(response.body.force_encoding("BINARY"))
      temp_input.rewind

      # fix
      if Ffmpeg::Video.determine_max_quality(temp_input.path) < quality.quality
        quality.unavailable!
        return
      end

      Ffmpeg::Video.encode_video(temp_input, temp_output, quality.quality)
      quality.video_file.attach(io: File.open(temp_output.path), filename: "#{video.id}_output.mp4")
      quality.completed!
    end
    ensure
    temp_input&.unlink
    temp_output&.unlink
    end
  end
end
