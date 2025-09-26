require "open3"

# Module for handling FFmpeg operations
# https://github.com/FFmpeg/FFmpeg
module Ffmpeg
  class << self
    # Checks if a video file contains an audio stream
    #
    # @param input_file [String] Path or URL to the input video file
    # @return [Hash] A hash containing :success (Boolean) and :has_audio (Boolean) if successful, or :error (String) if an error occurred
    def media_has_audio?(input_file)
      command = [ "ffprobe", "-i", input_file, "-show_streams", "-select_streams", "a", "-loglevel", "error" ]

      stdout, stderr, status = Open3.capture3(*command)

      if status.success?
        has_audio = stdout.include?("codec_type=audio")
        { success: true, has_audio: has_audio }
      else
        { success: false, error: stderr }
      end
    end

    # Extracts audio from a video file and saves it as an MP3
    #
    # @param input_file [String] Path or URL to the input video file
    # @param output_file [String] Path where the output audio file will be saved
    # @return [Hash] A hash containing :success (Boolean) and either :output_file (String) or :error (String)
    def extract_audio(input_file, output_file)
      command = [
        "ffmpeg",
        "-i", input_file,
        "-vn",                    # Disable video
        "-acodec", "libmp3lame",  # Use MP3 codec
        "-b:a", "16k",            # Set bit rate to 16 kbps
        "-ar", "12000",           # Set sample rate to 12 kHz
        "-ac", "1",               # Set to mono (1 channel)
        "-y",                     # Overwrite output file if it exists
        output_file
      ]

      _stdout, stderr, status = Open3.capture3(*command)

      if status.success?
        { success: true, output_file: output_file }
      else
        { success: false, error: stderr }
      end
    end

    # Concatenates multiple audio files into a single file
    #
    # @param input_list_file [String] Path to a text file containing the list of input files
    # @param output_file [String] Path where the output audio file will be saved
    # @return [Hash] A hash containing :success (Boolean) and either :output_file (String) or :error (String)
    def concat_audio(input_list_file, output_file)
      command = [
        "ffmpeg",
        "-f", "concat", # Use concat demuxer
        "-safe", "0",            # Don't restrict file paths
        "-i", input_list_file,   # Input file list
        "-c", "copy",           # Copy streams without re-encoding
        "-y",                   # Overwrite output file if it exists
        output_file # Output file
      ]

      _stdout, stderr, status = Open3.capture3(*command)

      if status.success?
        { success: true, output_file: output_file }
      else
        { success: false, error: stderr }
      end
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
        "1080p"
      elsif height >= 720 && width >= 1280 && bitrate >= 1_000_000 # 1 Mbps
        "720p"
      else
        "480p"
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

    private

    # Checks if FFmpeg is installed on the system
    #
    # @return [Boolean] True if FFmpeg is installed, false otherwise
    def ffmpeg_installed?
      system("which ffmpeg > /dev/null 2>&1")
    end
  end

  # raise "FFmpeg is not installed. Please install FFmpeg to use this module." unless ffmpeg_installed?
end
