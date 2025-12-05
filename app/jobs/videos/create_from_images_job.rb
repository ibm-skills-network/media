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
      temp_outputs = {}
      concat_file = nil
      output_file = nil

      begin
        # Process each chunk individually
        chunks.each_with_index do |chunk, i|
          Rails.logger.info("Processing chunk #{i + 1}/#{chunks.length}")

          temp_file = Tempfile.new([ "chunk_#{i}", ".mp4" ])
          temp_file.close
          temp_outputs[i] = temp_file

          command = [
            "ffmpeg",
            "-loop", "1",
            "-framerate", "30",
            "-i", chunk["image_url"],
            "-i", chunk["audio_url"],
            "-c:v", "av1_nvenc",
            "-pix_fmt", "yuv420p",
            "-r", "30",
            "-c:a", "aac",
            "-shortest",
            "-y",
            temp_file.path
          ]

          _stdout, stderr, status = Open3.capture3(*command)

          if status.success?
            Rails.logger.info("Chunk #{i + 1}/#{chunks.length} completed successfully")
          else
            Rails.logger.error("Chunk #{i + 1}/#{chunks.length} failed: #{stderr}")
            raise "FFmpeg chunk processing failed: #{stderr}"
          end
        end

        # Concatenate all chunks
        Rails.logger.info("Concatenating #{chunks.length} chunks")

        output_file = Tempfile.new([ "output", ".mp4" ])
        output_file.close
        concat_file = Tempfile.new([ "concat", ".txt" ])

        temp_outputs.each_value { |f| concat_file.write("file '#{f.path}'\n") }
        concat_file.close

        concat_command = [
          "ffmpeg", "-f", "concat", "-safe", "0", "-i", concat_file.path,
          "-c", "copy", "-fflags", "+genpts", "-y", output_file.path
        ]

        _stdout, stderr, status = Open3.capture3(*concat_command)

        if status.success?
          Rails.logger.info("Concatenation completed successfully")
        else
          Rails.logger.error("Concatenation failed: #{stderr}")
          raise "FFmpeg concatenation failed: #{stderr}"
        end

        File.open(output_file.path, "rb") do |file|
          video.video_file.attach(io: file, filename: "video_#{video.id}.mp4")
        end

      ensure
        temp_outputs&.each_value(&:unlink)
        concat_file&.unlink
        output_file&.unlink
      end
    end
  end
end
