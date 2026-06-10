module Videos
  class ImagesToVideoJob < ApplicationJob
    queue_as :gpu
    MAX_THREADS = 5

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
      task = ImagesToVideoTask.find_by(id: msg["args"].first["arguments"].first)
      task&.failed!
    end

    def perform(task_id, chunks, width, height)
      task = ImagesToVideoTask.includes(:images_to_video_profile).find(task_id)
      profile = task.images_to_video_profile
      task.processing!
      started_at = Time.current
      temp_files = []
      output_file = nil

      chunks_by_host = chunks.group_by do |chunk|
        URI.parse(chunk["image_url"]).host rescue nil
      end.compact

      clients_pool = Hash.new do |hash, host|
        hash[host] = Faraday.new(url: "https://#{host}") do |f|
          f.options.open_timeout = 2.0
          f.adapter Faraday.default_adapter
        end
      end

      begin
        mutex = Mutex.new
        image_files = []
        audio_files = []
        audio_durations = []

        chunks_by_host.each do |host, host_chunks|
          s3_client = clients_pool[host]

          host_chunks.each_slice(MAX_THREADS).with_index do |chunk_batch, batch_index|
            threads = chunk_batch.map.with_index do |chunk, batch_i|
              i = chunks.index(chunk)
              next if i.nil?

              Thread.new do
                image_file = Tempfile.new([ "image_#{i}", ".png" ])
                audio_file = Tempfile.new([ "audio_#{i}", ".mp3" ])

                image_file.binmode
                audio_file.binmode

                image_path = chunk["image_url"].gsub(%r{https?://#{host}}, "")
                audio_path = chunk["audio_url"].gsub(%r{https?://#{host}}, "")

                image_response = nil
                audio_response = nil

                img_retries = 0
                begin
                  image_response = s3_client.get(image_path)
                rescue Faraday::ConnectionFailed, Timeout::Error => e
                  if img_retries < 3
                    img_retries += 1
                    sleep(0.1 * img_retries)
                    retry
                  else
                    raise e
                  end
                end

                aud_retries = 0
                begin
                  audio_response = s3_client.get(audio_path)
                rescue Faraday::ConnectionFailed, Timeout::Error => e
                  if aud_retries < 3
                    aud_retries += 1
                    sleep(0.1 * aud_retries)
                    retry
                  else
                    raise e
                  end
                end

                if image_response.status != 200
                  raise "Failed to download image for chunk #{i}: HTTP #{image_response.status}"
                end

                if audio_response.status != 200
                  raise "Failed to download audio for chunk #{i}: HTTP #{audio_response.status}"
                end

                image_file.write(image_response.body)
                audio_file.write(audio_response.body)
                image_file.close
                audio_file.close

                duration_cmd = [ "ffprobe", "-i", audio_file.path, "-show_entries", "format=duration", "-v", "quiet", "-of", "csv=p=0" ]
                duration, _stderr, status = Open3.capture3(*duration_cmd)

                if !status.success? || duration.strip.empty?
                  raise "Failed to get audio duration for chunk #{i}"
                end

                mutex.synchronize do
                  image_files[i] = image_file
                  audio_files[i] = audio_file
                  audio_durations[i] = duration.strip
                  temp_files << image_file << audio_file
                end
              end
            end

            threads.compact.each(&:join)
          end
        end

        audio_durations.each_with_index do |duration, i|
          if duration.nil? || duration.empty?
            raise "Missing duration for chunk #{i}"
          end
        end

        # Build ffmpeg command with all inputs
        command = [ "ffmpeg" ]

        # Add all inputs with -loop and -t duration
        chunks.length.times do |i|
          command += [ "-loop", "1", "-r", "1", "-t", audio_durations[i], "-i", image_files[i].path ]
          command += [ "-i", audio_files[i].path ]
        end

        # Build filter_complex
        filter_parts = []

        # Scale and letterbox each video to target dimensions
        chunks.length.times do |i|
          video_input = i * 2
          filter_parts << "[#{video_input}:v]scale=w=#{width}:h=#{height}:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=#{width}:#{height}:(ow-iw)/2:(oh-ih)/2,setsar=1[v#{i}]"
        end

        # Build concat inputs
        v_concat = chunks.length.times.map { |i| "[v#{i}]" }.join("")
        a_concat = chunks.length.times.map { |i| "[#{i * 2 + 1}:a]" }.join("")

        # Final concat
        filter_parts << "#{v_concat}concat=n=#{chunks.length}:v=1:a=0[v]"
        filter_parts << "#{a_concat}concat=n=#{chunks.length}:v=0:a=1[a]"

        output_file = Tempfile.new([ "output", ".#{profile.container}" ])
        output_file.close

        command += [
          "-filter_complex", filter_parts.join("; "),
          "-map", "[v]",
          "-map", "[a]",
          "-c:v", profile.codec,
          "-pix_fmt", "yuv420p",
          *profile.extra_video_options,
          "-c:a", profile.audio_codec,
          "-y",
          output_file.path
        ]

        _stdout, stderr, status = Open3.capture3(*command)

        if !status.success?
          raise "FFmpeg processing failed: #{stderr}"
        end

        File.open(output_file.path, "rb") do |file|
          task.video_file.attach(io: file, filename: "images_to_video_#{task.id}.#{profile.container}")
        end
        task.update!(completion_time: (Time.current - started_at))
        task.success!
      rescue => e
        task.pending!
        raise e
      ensure
        temp_files.each(&:unlink)
        output_file&.unlink
      end
    end
  end
end
