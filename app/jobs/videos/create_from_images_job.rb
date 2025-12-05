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
      output_file = nil

      begin
        Rails.logger.info("Downloading #{chunks.length} files")

        # Download all files in parallel
        mutex = Mutex.new
        image_files = []
        audio_files = []
        audio_durations = []

        threads = chunks.map.with_index do |chunk, i|
          Thread.new do
            image_file = Tempfile.new([ "image_#{i}", ".png" ])
            audio_file = Tempfile.new([ "audio_#{i}", ".mp3" ])

            image_file.binmode
            audio_file.binmode
            image_file.write(URI.open(chunk["image_url"]).read)
            audio_file.write(URI.open(chunk["audio_url"]).read)
            image_file.close
            audio_file.close

            # Get audio duration using ffprobe
            duration_cmd = [ "ffprobe", "-i", audio_file.path, "-show_entries", "format=duration", "-v", "quiet", "-of", "csv=p=0" ]
            duration, _stderr, _status = Open3.capture3(*duration_cmd)

            mutex.synchronize do
              image_files[i] = image_file
              audio_files[i] = audio_file
              audio_durations[i] = duration.strip
              temp_files << image_file << audio_file
            end

            Rails.logger.info("Downloaded chunk #{i + 1}/#{chunks.length}")
          end
        end

        threads.each(&:join)

        Rails.logger.info("Processing all chunks in single ffmpeg command")

        # Build ffmpeg command with all inputs
        command = [ "ffmpeg" ]

        # Add all inputs with -loop and -t duration
        chunks.length.times do |i|
          command += [ "-loop", "1", "-t", audio_durations[i], "-i", image_files[i].path ]
          command += [ "-i", audio_files[i].path ]
        end

        # Build filter_complex
        filter_parts = []

        # Scale and trim each video
        chunks.length.times do |i|
          video_input = i * 2
          filter_parts << "[#{video_input}:v]scale=1280:720,setsar=1,trim=duration=#{audio_durations[i]}[v#{i}]"
        end

        # Build concat inputs
        v_concat = chunks.length.times.map { |i| "[v#{i}]" }.join("")
        a_concat = chunks.length.times.map { |i| "[#{i * 2 + 1}:a]" }.join("")

        # Final concat
        filter_parts << "#{v_concat}concat=n=#{chunks.length}:v=1:a=0[v]"
        filter_parts << "#{a_concat}concat=n=#{chunks.length}:v=0:a=1[a]"

        output_file = Tempfile.new([ "output", ".mp4" ])
        output_file.close

        command += [
          "-filter_complex", filter_parts.join("; "),
          "-map", "[v]",
          "-map", "[a]",
          "-c:v", "av1_nvenc",
          "-pix_fmt", "yuv420p",
          "-c:a", "aac",
          "-y",
          output_file.path
        ]

        Rails.logger.info("Running ffmpeg command")
        _stdout, stderr, status = Open3.capture3(*command)

        if status.success?
          Rails.logger.info("FFmpeg completed successfully")
        else
          Rails.logger.error("FFmpeg failed: #{stderr}")
          raise "FFmpeg processing failed: #{stderr}"
        end

        File.open(output_file.path, "rb") do |file|
          video.video_file.attach(io: file, filename: "video_#{video.id}.mp4")
        end

      ensure
        temp_files.each(&:unlink)
        output_file&.unlink
      end
    end
  end
end
