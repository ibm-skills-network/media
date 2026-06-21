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

  # Removes all HLS objects for a task.
  def self.purge(task_id)
    new(nil, task_id).purge
  end

  def initialize(local_hls_dir, task_id)
    @local_hls_dir = local_hls_dir
    @task_id = task_id
  end

  def upload_dir
    # Clear stale objects from a prior partial run — otherwise a shorter new run
    # leaves orphaned segments behind the freshly-written manifest.
    purge

    Dir.glob(File.join(@local_hls_dir, "**/*")).each do |path|
      next unless File.file?(path)
      relative = path.sub(/\A#{Regexp.escape(@local_hls_dir)}\/?/, "")
      put_object(path, "#{prefix}#{relative}")
    end
    public_url("#{prefix}master.m3u8")
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

  def public_url(key)
    "#{Settings.dig(:ibmcos, :endpoint).chomp('/')}/#{bucket_name}/#{key}"
  end

  def bucket_name
    Settings.dig(:ibmcos, :bucket)
  end
end
