class VideosController < ApplicationController
  def create
    video = Video.new(video_params)

    if video.save
      render json: {
        id: video.id,
        message: "Video uploaded successfully",
        status: "success"
      }, status: :created
    else
      render json: {
        errors: video.errors.full_messages,
        status: "error"
      }, status: :unprocessable_entity
    end
  end

  def index
    videos = Video.all
    render json: videos.map { |video|
      {
        id: video.id,
        title: video.title,
        created_at: video.created_at,
        has_video_file: video.video_file.attached?
      }
    }
  end

  def show
    video = Video.find(params[:id])
    render json: {
      id: video.id,
      title: video.title,
      created_at: video.created_at,
      has_video_file: video.video_file.attached?,
      video_file_url: video.video_file.attached? ? url_for(video.video_file) : nil
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Video not found" }, status: :not_found
  end

  def test_1080p_conversion
    require "open3"
    require "tempfile"

    begin
      # Use the hardcoded URL
      test_url = "https://cf-course-data-dev.static.labs.skills.network/nCOIWfKzUan2SZFSb8tBPA/4K%20ULtra%20HD%20%20SAMSUNG%20UHD%20Demo-%20LED%20TV%20-%204K%20Ultra%20HD%20-1080p-%20h264-%20youtube-.mp4"

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
        "-crf", "30",
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
        status: "success"
      }, status: :ok

    rescue => e
      render json: {
        error: "NVENC codec test failed: #{e.message}",
        status: "error"
      }, status: :internal_server_error
    end
  end

  private

  def video_params
    params.permit(:title, :video_file)
  end
end
