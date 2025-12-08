module Videos
  class CreateFromImagesJob < ApplicationJob
    queue_as :gpu
    MAX_THREADS = 5

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
        Rails.logger.info("Downloading #{chunks.length} files with max #{MAX_THREADS} threads")

        # Download all files in parallel with thread pool
        mutex = Mutex.new
        image_files = []
        audio_files = []
        audio_durations = []

        # Process chunks in batches using thread pool
        chunks.each_slice(MAX_THREADS).with_index do |chunk_batch, batch_index|
          threads = chunk_batch.map.with_index do |chunk, batch_i|
            i = batch_index * MAX_THREADS + batch_i
            Thread.new do
              image_file = Tempfile.new([ "image_#{i}", ".png" ])
              audio_file = Tempfile.new([ "audio_#{i}", ".mp3" ])

              image_file.binmode
              audio_file.binmode

              # Download using Faraday
              Rails.logger.info("Downloading chunk #{i}: image from #{chunk['image_url'][0..50]}...")
              image_response = Faraday.get(chunk["image_url"])
              Rails.logger.info("Chunk #{i} image response: status=#{image_response.status}, size=#{image_response.body.bytesize} bytes")

              Rails.logger.info("Downloading chunk #{i}: audio from #{chunk['audio_url'][0..50]}...")
              audio_response = Faraday.get(chunk["audio_url"])
              Rails.logger.info("Chunk #{i} audio response: status=#{audio_response.status}, size=#{audio_response.body.bytesize} bytes")

              if image_response.status != 200
                raise "Failed to download image for chunk #{i}: HTTP #{image_response.status}"
              end

              if audio_response.status != 200
                raise "Failed to download audio for chunk #{i}: HTTP #{audio_response.status}"
              end

              image_file.write(image_response.body)
              audio_file.write(audio_response.body)
              image_file.flush
              audio_file.flush
              image_file.close
              audio_file.close

              # Get audio duration using ffprobe
              duration_cmd = [ "ffprobe", "-i", audio_file.path, "-show_entries", "format=duration", "-v", "quiet", "-of", "csv=p=0" ]
              duration, stderr, status = Open3.capture3(*duration_cmd)

              if !status.success? || duration.strip.empty?
                Rails.logger.error("Failed to get duration for chunk #{i}: stderr='#{stderr}', stdout='#{duration}', status=#{status.exitstatus}")
                Rails.logger.error("Audio file path: #{audio_file.path}, exists: #{File.exist?(audio_file.path)}, size: #{File.size(audio_file.path) rescue 'unknown'}")
                raise "Failed to get audio duration for chunk #{i}"
              end

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
          Rails.logger.info("Completed batch #{batch_index + 1}/#{(chunks.length.to_f / MAX_THREADS).ceil}")
        end

        Rails.logger.info("All downloads complete")
        Rails.logger.info("Audio durations: #{audio_durations.inspect}")

        # Verify all durations were captured
        audio_durations.each_with_index do |duration, i|
          if duration.nil? || duration.empty?
            raise "Missing duration for chunk #{i}"
          end
        end

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
