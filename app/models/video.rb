require "open3"
require "tempfile"

class Video < ApplicationRecord
  has_one_attached :video_file
  has_many :videos_qualities, class_name: "Videos::Quality"

  def create_1080p_quality!(cuda: false, video_url: nil)
    # https://cf-course-data-dev.static.labs.skills.network/nCOIWfKzUan2SZFSb8tBPA/4K%20ULtra%20HD%20%20SAMSUNG%20UHD%20Demo-%20LED%20TV%20-%204K%20Ultra%20HD%20-1080p-%20h264-%20youtube-.mp4?t=0
    temp_input = nil
    temp_output = nil

    begin
      temp_input = Tempfile.new([ "#{id}_input", File.extname(video_file.name) || ".mp4" ])
      temp_output = Tempfile.new([ "#{id}_output", ".mp4" ])

      temp_input.binmode
      if video_url
        temp_input.write(Faraday.get(video_url).body.force_encoding("BINARY"))
      else
        temp_input.write(video_file.download)
      end
      temp_input.rewind
      # if Videos::Quality.qualities[Ffmpeg.determine_max_quality(temp_input.path)] < Videos::Quality.qualities["1080p"]
      #   videos_qualities.create!(quality: "1080p", status: "unavailable")
      #   return
      # end
      method_name = cuda ? "convert_to_1080p_cuda" : "convert_to_1080p"
      send(method_name, temp_input.path, temp_output.path)
      quality_record = Videos::Quality.create!(quality: "1080p", status: "completed", video: self)
      quality_record.video_file.attach(io: File.open(temp_output.path), filename: "#{title}_1080p.mp4", content_type: "video/mp4")
    ensure
      temp_input&.unlink
      temp_output&.unlink
    end
  end

  private

  def convert_to_1080p(input_path, output_path)
    command = [
      "ffmpeg",
      "-i", input_path,
      "-vf", "scale='min(1920,iw)':'min(1080,ih)':flags=lanczos:force_original_aspect_ratio=decrease",
      "-c:v", "libaom-av1",
      "-b:v", "2900k",
      "-crf", "30",
      "-cpu-used", "4",
      "-c:a", "aac",
      "-b:a", "128k",
      "-ac", "2",
      "-y",
      output_path
    ]
    _stdout, stderr, status = Open3.capture3(*command)
    raise "Failed to convert to 1080p: #{stderr}" unless status.success?
  end

  def convert_to_1080p_cuda(input_path, output_path)
    command = [
      "ffmpeg",
      "-hwaccel", "cuda",
      "-i", input_path,
      "-vf", "scale_cuda='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease",
      "-c:v", "av1_nvenc",
      "-b:v", "2900k",
      "-preset", "medium",
      "-c:a", "aac",
      "-b:a", "128k",
      "-ac", "2",
      "-y",
      output_path
    ]
    _stdout, stderr, status = Open3.capture3(*command)
    raise "Failed to convert to 1080p with CUDA: #{stderr}" unless status.success?
  end
end
