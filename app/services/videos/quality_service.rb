module Videos
  class QualityService
    QUALITY_CONFIGS = {
      "1080p" => {
        width: 1920,
        height: 1080,
        bitrate: "2900k"
      },
      "720p" => {
        width: 1280,
        height: 720,
        bitrate: "1800k"
      },
      "480p" => {
        width: 854,
        height: 480,
        bitrate: "1000k"
      }
    }.freeze

    class << self
      def encode_quality(video, quality)
        validate_quality!(quality)

        temp_input = nil
        temp_output = nil

        begin
          temp_input = create_input_file(video)
          temp_output = create_output_file(video, quality)

          write_input_data(video, temp_input)
          execute_conversion(quality, temp_input.path, temp_output.path)

          quality_record = create_quality_record(video, quality)
          attach_output_file(video, quality_record, quality, temp_output.path)

          quality_record
        ensure
          temp_input&.unlink
          temp_output&.unlink
        end
      end

      private

      def validate_quality!(quality)
        unless QUALITY_CONFIGS.key?(quality)
          raise ArgumentError, "Invalid quality: #{quality}. Valid options: #{QUALITY_CONFIGS.keys.join(', ')}"
        end
      end

      def create_input_file(video)
        Tempfile.new([ "#{video.id}_input", File.extname(video.video_file.filename.to_s) || ".mp4" ])
      end

      def create_output_file(video, quality)
        Tempfile.new([ "#{video.id}_output_#{quality}", ".mp4" ])
      end

      def write_input_data(video, temp_input)
        temp_input.binmode
        temp_input.write(video.video_file.download)
        temp_input.rewind
      end

      def execute_conversion(quality, input_path, output_path)
        command = build_ffmpeg_command(quality, input_path, output_path)
        _stdout, stderr, status = Open3.capture3(*command)
        raise "Failed to convert to #{quality}: #{stderr}" unless status.success?
      end

      def build_ffmpeg_command(quality, input_path, output_path)
        config = QUALITY_CONFIGS[quality]

        [
          "ffmpeg",
          "-i", input_path,
          "-vf", "scale='min(#{config[:width]},iw)':'min(#{config[:height]},ih)':flags=lanczos:force_original_aspect_ratio=decrease",
          "-c:v", "av1_nvenc",
          "-b:v", config[:bitrate],
          "-preset", "p4",
          "-c:a", "aac",
          "-b:a", "128k",
          "-ac", "2",
          "-y",
          output_path
        ]
      end

      def create_quality_record(video, quality)
        Videos::Quality.create!(
          quality: quality,
          status: "completed",
          video: video
        )
      end

      def attach_output_file(video, quality_record, quality, output_path)
        quality_record.video_file.attach(
          io: File.open(output_path),
          filename: "#{video.title}_#{quality}.mp4",
          content_type: "video/mp4"
        )
      end
    end
  end
end