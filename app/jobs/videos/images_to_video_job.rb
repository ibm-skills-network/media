module Videos
  class ImagesToVideoJob < ApplicationJob
    queue_as :gpu
    MAX_THREADS = 5

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
      task = ImagesToVideoTask.find_by(id: msg["args"].first["arguments"].first)
      task&.failed!
    end

    def perform(task_id, chunks, width = 1280, height = 720)
      task = ImagesToVideoTask.find(task_id)
      task.processing!
      temp_files = []
      output_file = nil

      begin
        # Download all files in parallel with thread pool
        mutex = Mutex.new
        image_files = []
        audio_files = []
        audio_durations = []

        chunks.each_slice(MAX_THREADS).with_index do |chunk_batch, batch_index|
          threads = chunk_batch.map.with_index do |chunk, batch_i|
            i = batch_index * MAX_THREADS + batch_i
            Thread.new do
              image_file = Tempfile.new([ "image_#{i}", ".png" ])
              audio_file = Tempfile.new([ "audio_#{i}", ".mp3" ])

              image_file.binmode
              audio_file.binmode

              image_response = Faraday.get(chunk["image_url"])

              audio_response = Faraday.get(chunk["audio_url"])

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

          threads.each(&:join)
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
          command += [ "-loop", "1", "-t", audio_durations[i], "-i", image_files[i].path ]
          command += [ "-i", audio_files[i].path ]
        end

        # Build filter_complex
        filter_parts = []

        # Scale and letterbox each video to target dimensions
        chunks.length.times do |i|
          video_input = i * 2
          filter_parts << "[#{video_input}:v]scale=w=#{width}:h=#{height}:force_original_aspect_ratio=decrease,pad=#{width}:#{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,trim=duration=#{audio_durations[i]}[v#{i}]"
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

        _stdout, stderr, status = Open3.capture3(*command)

        if !status.success?
          raise "FFmpeg processing failed: #{stderr}"
        end

        File.open(output_file.path, "rb") do |file|
          task.video_file.attach(io: file, filename: "images_to_video_#{task.id}.mp4")
        end
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
