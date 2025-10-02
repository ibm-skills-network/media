require "open3"

# Module for handling FFmpeg video operations
module Ffmpeg
  module Video
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
      # determines mime type and name of the external video
      # "https://cf-course-data-dev.static.labs.skills.network/zxXAVPH4SeNxCytSVdqL3A/1min%20-1-.mp4?t=0"
      def mime_type(url)
        begin
          response = Faraday.head(url)
        rescue Faraday::ConnectionFailed
          return nil
        end

       response.headers["Content-Type"]
      end
      # Extracts video metadata using ffprobe
      #
      # @param file_path [String] Path to the video file
      # @return [Hash] Parsed JSON metadata from ffprobe
      def video_metadata(file_path)
        command = [
          "ffprobe",
          "-v", "quiet",
          "-print_format", "json",
          "-show_format",
          "-show_streams",
          file_path
        ]

        stdout, _stderr, status = Open3.capture3(*command)
        raise "Failed to extract video metadata" unless status.success?

        JSON.parse(stdout)
      end

      # Determines the maximum quality level of a video based on resolution and bitrate
      #
      # @param file_path [String] Path to the video file
      # @return [String] Quality level (480p, 720p, 1080p)
      def determine_max_quality(file_path)
        metadata = video_metadata(file_path)

        video_stream = metadata["streams"].find { |stream| stream["width"].present? && stream["height"].present? }

        width = video_stream["width"]
        height = video_stream["height"]
        bitrate = video_stream["bit_rate"].to_i

        if height >= 1080 && width >= 1920 && bitrate >= 2_000_000 # 2 Mbps
          Videos::Quality.qualities["1080p"]
        elsif height >= 720 && width >= 1280 && bitrate >= 1_000_000 # 1 Mbps
          Videos::Quality.qualities["720p"]
        else
          Videos::Quality.qualities["480p"]
        end
      end

      # Checks if CUDA hardware acceleration is supported by FFmpeg
      #
      # @return [Hash] A hash containing :success (Boolean) and :cuda_supported (Boolean) if successful, or :error (String) if an error occurred
      def cuda_supported?
        command = [ "ffmpeg", "-hide_banner", "-encoders" ]

        stdout, stderr, status = Open3.capture3(*command)

        if status.success? && (stdout.include?("nvenc") || stdout.include?("av1_nvenc"))
          { cuda_supported: true }
        elsif status.success?
          { cuda_supported: false, available_encoders: stdout.split("\n").map { |line| line.split(" ")[0] } }
        else
          { success: false, error: stderr }
        end
      end

      # Encodes a video file to a specific quality using CUDA acceleration
      #
      # @param input_path [String] Path to the input video file
      # @param output_path [String] Path where the output video file will be saved
      # @param quality [String] Quality level (480p, 720p, 1080p)
      # @return [Hash] A hash containing :success (Boolean) and either :output_file (String) or :error (String)
      def encode_video(input_path, output_path, quality)
        unless QUALITY_CONFIGS.key?(quality)
          return { success: false, error: "Invalid quality: #{quality}. Valid options: #{QUALITY_CONFIGS.keys.join(', ')}" }
        end

        config = QUALITY_CONFIGS[quality]

        command = [
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

        _stdout, stderr, status = Open3.capture3(*command)

        if status.success?
          { success: true, output_file: output_path }
        else
          { success: false, error: stderr }
        end
      end
    end
  end
end
