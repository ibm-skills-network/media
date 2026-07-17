module DubbingFfprobe
  module_function

  def duration_seconds(path)
    out, _err, status = Open3.capture3(
      "ffprobe", "-v", "error",
      "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1",
      path
    )
    raise "ffprobe failed for #{path}" unless status.success?
    out.strip.to_f
  end
end
