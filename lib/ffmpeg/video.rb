require "open3"

# Module for handling FFmpeg video operations
module Ffmpeg
  module Video
    class << self
      # determines mime type and name of the external video
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

      # Extracts video metadata from a URL using ffprobe
      #
      # @param url [String] URL to the video file
      # @return [Hash] Parsed JSON metadata from ffprobe
      def video_metadata_from_url(url)
        command = [
          "ffprobe",
          "-v", "quiet",
          "-print_format", "json",
          "-show_format",
          "-show_streams",
          url
        ]

        stdout, _stderr, status = Open3.capture3(*command)
        raise "Failed to extract video metadata from URL" unless status.success?

        JSON.parse(stdout)
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
      # @param transcoding_profile [Videos::Quality::TranscodingProfile] The transcoding profile to use
      # @return [Hash] A hash containing :success (Boolean) and either :output_file (String) or :error (String)
      def encode_video(input_path, output_path, transcoding_profile)
        command = [
          "ffmpeg",
          "-hwaccel", "cuda",
          "-hwaccel_output_format", "cuda",
          "-i", input_path,
          "-vf", "scale_cuda='min(#{transcoding_profile.width},iw)':'min(#{transcoding_profile.height},ih)'",
          "-c:v", transcoding_profile.codec,
          "-b:v", transcoding_profile.bitrate_string,
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
