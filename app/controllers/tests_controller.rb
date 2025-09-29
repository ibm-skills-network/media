class TestsController < ApplicationController
  def test_1080p_conversion
    require "open3"
    require "tempfile"

    begin
      # Use the hardcoded URL
      test_url = "https://cf-course-data-dev.static.labs.skills.network/zxXAVPH4SeNxCytSVdqL3A/1min%20-1-.mp4?t=0"

      # Create temp files
      temp_input = Tempfile.new([ "test_input", ".mp4" ])
      temp_output = Tempfile.new([ "test_output", ".mp4" ])

      temp_input.binmode
      temp_input.write(Faraday.get(test_url).body.force_encoding("BINARY"))
      temp_input.rewind

      # FFmpeg conversion command (inlined from Video model)
      command = [
        "ffmpeg",
        "-i", temp_input.path,
        "-vf", "scale='min(1920,iw)':'min(1080,ih)':flags=lanczos:force_original_aspect_ratio=decrease",
        "-c:v", "libaom-av1",
        "-b:v", "2900k",
        "-cpu-used", "4",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ac", "2",
        "-y",
        temp_output.path
      ]

      _stdout, stderr, status = Open3.capture3(*command)
      raise "Failed to convert to 1080p: #{stderr}" unless status.success?

      # Check if output file was created and has content
      output_size = File.size(temp_output.path)

      render json: {
        message: "Test 1080p conversion completed successfully (no database operations)",
        output_file_size: output_size,
        status: "success"
      }, status: :ok

    rescue => e
      render json: {
        error: "Test conversion failed: #{e.message}",
        status: "error"
      }, status: :internal_server_error
    ensure
      # Clean up temp files
      temp_input&.unlink
      temp_output&.unlink
    end
  end

  def test_nvenc_codecs
    require "open3"

    begin
      # Check if NVIDIA hardware acceleration is available
      stdout, stderr, status = Open3.capture3("ffmpeg", "-hwaccels")

      nvenc_available = stdout.include?("cuda")

      # Check if av1_nvenc encoder is available
      stdout_encoders, stderr_encoders, status_encoders = Open3.capture3("ffmpeg", "-encoders")

      av1_nvenc_available = stdout_encoders.include?("av1_nvenc")
      h264_nvenc_available = stdout_encoders.include?("h264_nvenc")
      hevc_nvenc_available = stdout_encoders.include?("hevc_nvenc")

      render json: {
        cuda_hwaccel_available: nvenc_available,
        av1_nvenc_encoder_available: av1_nvenc_available,
        h264_nvenc_encoder_available: h264_nvenc_available,
        hevc_nvenc_encoder_available: hevc_nvenc_available,
        ffmpeg_hwaccels_output: stdout,
        all_encoders_output: stdout_encoders,
        status: "success"
      }, status: :ok

    rescue => e
      render json: {
        error: "NVENC codec test failed: #{e.message}",
        status: "error"
      }, status: :internal_server_error
    end
  end

  def testvideonv
    require "open3"
    require "tempfile"

    begin
      # Use the hardcoded URL
      test_url = "https://cf-course-data-dev.static.labs.skills.network/zxXAVPH4SeNxCytSVdqL3A/1min%20-1-.mp4?t=0"

      # Create temp files
      temp_input = Tempfile.new([ "test_input", ".mp4" ])
      temp_output = Tempfile.new([ "test_output", ".mp4" ])

      temp_input.binmode
      temp_input.write(Faraday.get(test_url).body.force_encoding("BINARY"))
      temp_input.rewind

      # FFmpeg conversion command with AV1 NVENC
      command = [
        "ffmpeg",
        "-i", temp_input.path,
        "-vf", "scale='min(1920,iw)':'min(1080,ih)':flags=lanczos:force_original_aspect_ratio=decrease",
        "-c:v", "av1_nvenc",
        "-b:v", "2900k",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ac", "2",
        "-y",
        temp_output.path
      ]

      _stdout, stderr, status = Open3.capture3(*command)
      raise "Failed to convert to 1080p: #{stderr}" unless status.success?

      # Check if output file was created and has content
      output_size = File.size(temp_output.path)

      render json: {
        message: "Test 1080p conversion with AV1 NVENC completed successfully (no database operations)",
        output_file_size: output_size,
        status: "success"
      }, status: :ok

    rescue => e
      render json: {
        error: "Test conversion failed: #{e.message}",
        status: "error"
      }, status: :internal_server_error
    ensure
      # Clean up temp files
      temp_input&.unlink
      temp_output&.unlink
    end
  end
end