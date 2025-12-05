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
      chunk_files = []

      begin
        # Download all files to temp
        chunks.each_with_index do |chunk, i|
          image_file = Tempfile.new([ "image_#{i}", ".png" ])
          audio_file = Tempfile.new([ "audio_#{i}", ".mp3" ])
          chunk_output = Tempfile.new([ "chunk_#{i}", ".mp4" ])

          temp_files << image_file << audio_file << chunk_output

          image_file.binmode
          audio_file.binmode
          image_file.write(URI.open(chunk["image_url"]).read)
          audio_file.write(URI.open(chunk["audio_url"]).read)
          image_file.close
          audio_file.close

          # Process each chunk individually
          command = [
            "ffmpeg", "-y",
            "-loop", "1", "-i", image_file.path,
            "-i", audio_file.path,
            "-vf", "fps=30,format=yuv420p",
            "-c:v", "av1_nvenc",
            "-c:a", "aac",
            "-shortest",
            chunk_output.path
          ]

          _stdout, stderr, status = Open3.capture3(*command)
          raise "FFmpeg chunk processing failed: #{stderr}" unless status.success?

          chunk_files << chunk_output.path
        end

        # Concatenate all chunks
        output_file = Tempfile.new([ "output", ".mp4" ])
        concat_file = Tempfile.new([ "concat", ".txt" ])

        chunk_files.each { |f| concat_file.write("file '#{f}'\n") }
        concat_file.close

        concat_command = [
          "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_file.path,
          "-c", "copy", output_file.path
        ]

        _stdout, stderr, status = Open3.capture3(*concat_command)
        raise "FFmpeg concatenation failed: #{stderr}" unless status.success?

        video_file_attachment = video.video_file
        File.open(output_file.path, "rb") do |file|
          video_file_attachment.attach(io: file, filename: "video_#{video.id}.mp4")
        end

      ensure
        temp_files.each(&:unlink)
        output_file&.unlink
        concat_file&.unlink
      end
    end
  end
end
