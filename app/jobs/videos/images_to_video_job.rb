module Videos
  class ImagesToVideoJob < ApplicationJob
    queue_as :gpu
    MAX_CONCURRENCY = 5
    MAX_DOWNLOAD_RETRIES = 3
    CONNECT_TIMEOUT = 2
    REQUEST_TIMEOUT = 5

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

      begin
        image_files = Array.new(chunks.length)
        audio_files = Array.new(chunks.length)
        audio_durations = Array.new(chunks.length)

        # Build a tempfile + download spec for every asset up front.
        # libcurl (via Hydra) multiplexes all transfers on a single thread,
        # so we no longer open one socket per Ruby thread — this is the fix
        # for the socket starvation that caused Net::OpenTimeout under load.
        downloads = []
        chunks.each_with_index do |chunk, i|
          image_file = Tempfile.new([ "image_#{i}", ".png" ])
          audio_file = Tempfile.new([ "audio_#{i}", ".mp3" ])
          image_file.binmode
          audio_file.binmode

          image_files[i] = image_file
          audio_files[i] = audio_file
          temp_files << image_file << audio_file

          downloads << { index: i, kind: :image, url: chunk["image_url"], file: image_file }
          downloads << { index: i, kind: :audio, url: chunk["audio_url"], file: audio_file }
        end

        # Resilient download with exponential backoff + jitter. Failures are
        # collected per round and re-queued; the backoff sleep happens between
        # hydra.run rounds so it never blocks live connections.
        hydra = Typhoeus::Hydra.new(max_concurrency: MAX_CONCURRENCY)
        pending = downloads
        attempt = 0

        loop do
          failures = []

          pending.each do |download|
            request = Typhoeus::Request.new(
              download[:url],
              method: :get,
              connecttimeout: CONNECT_TIMEOUT,
              timeout: REQUEST_TIMEOUT
            )
            # on_complete runs on the hydra.run thread, so these mutations
            # need no synchronization.
            request.on_complete do |response|
              if response.success?
                download[:file].write(response.body)
              else
                failures << download
              end
            end
            hydra.queue(request)
          end

          hydra.run

          break if failures.empty?

          attempt += 1
          if attempt > MAX_DOWNLOAD_RETRIES
            failed = failures.first
            raise "Failed to download #{failed[:kind]} for chunk #{failed[:index]} after #{MAX_DOWNLOAD_RETRIES} retries"
          end

          sleep((0.05 * (2**attempt)) + rand(0.02..0.08))
          pending = failures
        end

        image_files.each(&:close)
        audio_files.each(&:close)

        chunks.length.times do |i|
          duration_cmd = [ "ffprobe", "-i", audio_files[i].path, "-show_entries", "format=duration", "-v", "quiet", "-of", "csv=p=0" ]
          duration, _stderr, status = Open3.capture3(*duration_cmd)

          if !status.success? || duration.strip.empty?
            raise "Failed to get audio duration for chunk #{i}"
          end

          audio_durations[i] = duration.strip
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
