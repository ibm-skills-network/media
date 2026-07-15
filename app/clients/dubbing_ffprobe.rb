module DubbingFfprobe
  module_function

  # Returns the audio/video duration in seconds as a float
  def duration_seconds(path)
    Ffmpeg::Video.video_metadata(path).dig("format", "duration").to_f
  rescue RuntimeError => e
    raise "ffprobe failed for #{path}: #{e.message}"
  end
end
