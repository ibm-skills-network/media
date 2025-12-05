require "open-uri"

module Videos
  class CreateFromImagesJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
      video = Video.find(msg["args"].first)
      video.update(external_video_link: nil) if video.present?
    end

    def perform(video_id, chunks)
      video = Video.find(video_id)

      temp_files = []
      concat_file = Tempfile.new([ "concat", ".txt" ])
      output_file = Tempfile.new([ "output", ".mp4" ])

      begin
        chunks.each_with_index do |chunk, index|
          image_file = Tempfile.new([ "image_#{index}", ".png" ])
          audio_file = Tempfile.new([ "audio_#{index}", ".mp3" ])
          chunk_output = Tempfile.new([ "chunk_#{index}", ".mp4" ])

          temp_files << image_file << audio_file << chunk_output

          image_file.binmode
          audio_file.binmode
          image_file.write(URI.open(chunk["image_url"]).read)
          audio_file.write(URI.open(chunk["audio_url"]).read)
          image_file.close
          audio_file.close

          command = [
            "ffmpeg",
            "-y",
            "-loop", "1",
            "-i", image_file.path,
            "-i", audio_file.path,
            "-c:v", "libx264",
            "-tune", "stillimage",
            "-c:a", "aac",
            "-b:a", "192k",
            "-pix_fmt", "yuv420p",
            "-shortest",
            chunk_output.path
          ]

          _stdout, stderr, status = Open3.capture3(*command)

          unless status.success?
            raise "FFmpeg chunk creation failed: #{stderr}"
          end

          concat_file.write("file '#{chunk_output.path}'\n")
        end

        concat_file.close

        concat_command = [
          "ffmpeg",
          "-y",
          "-f", "concat",
          "-safe", "0",
          "-i", concat_file.path,
          "-c", "copy",
          output_file.path
        ]

        _stdout, stderr, status = Open3.capture3(*concat_command)

        unless status.success?
          raise "FFmpeg concatenation failed: #{stderr}"
        end

        video_file_attachment = video.video_file
        File.open(output_file.path, "rb") do |file|
          video_file_attachment.attach(io: file, filename: "video_#{video.id}.mp4")
        end

        video.update!(external_video_link: Rails.application.routes.url_helpers.rails_blob_url(video.video_file, host: Settings.host))

      ensure
        temp_files.each(&:unlink)
        concat_file.unlink
        output_file.unlink
      end
    end
  end
end
