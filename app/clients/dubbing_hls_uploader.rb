class DubbingHlsUploader
  CONTENT_TYPES = {
    ".m3u8"   => "application/vnd.apple.mpegurl",
    ".mp4"    => "video/iso.segment",
    ".m4s"    => "video/iso.segment",
    ".vtt"    => "text/vtt",
    ".webvtt" => "text/vtt",
    ".srt"    => "application/x-subrip",
    ".json"   => "application/json"
  }.freeze

  def self.upload_dir(local_hls_dir, task_id)
    new(local_hls_dir, task_id).upload_dir
  end

  # Removes all HLS objects for a task
  def self.purge(task_id)
    new(nil, task_id).purge
  end

  def initialize(local_hls_dir, task_id)
    @local_hls_dir = local_hls_dir
    @task_id = task_id
  end

  def upload_dir
    # Wipe any leftovers from a prior partial run so we don't orphan stale segments
    purge

    Dir.glob(File.join(@local_hls_dir, "**/*")).each do |path|
      next unless File.file?(path)
      relative = path.sub(/\A#{Regexp.escape(@local_hls_dir)}\/?/, "")
      put_object(path, "#{prefix}#{relative}")
    end
    hls_master_url
  end

  def purge
    bucket.objects(prefix: prefix).batch_delete!
  end

  private

  def prefix
    "dubbing/#{@task_id}/hls/"
  end

  def put_object(local_path, key)
    bucket.object(key).upload_file(
      local_path,
      content_type: CONTENT_TYPES[File.extname(local_path)] || "application/octet-stream"
    )
  end

  def bucket
    ActiveStorage::Blob.service.bucket
  end

  # Players load sibling files relative to master.m3u8, so we serve the whole bundle
  # through the dubbing_tasks#hls endpoint instead of opening the bucket up
  def hls_master_url
    path = "/api/v1/async/videos/dubbing_tasks/#{@task_id}/hls/master.m3u8"
    host = Settings.dig(:host)
    host.present? ? "#{host.to_s.chomp('/')}#{path}" : path
  end
end
