require "open3"

# Module for handling FFmpeg audio operations
module Ffmpeg
  module Audio
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
    end
  end
end
