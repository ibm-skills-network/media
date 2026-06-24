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

  def self.upload_dir(local_hls_dir, task)
    new(local_hls_dir, task).upload_dir
  end

  # Removes all HLS objects for a task
  def self.purge(task)
    new(nil, task).purge
  end

  def initialize(local_hls_dir, task)
    @local_hls_dir = local_hls_dir
    @task = task
  end

  def upload_dir
    # Wipe leftovers from a prior partial run so we don't orphan stale segments
    purge

    Dir.glob(File.join(@local_hls_dir, "**/*")).each do |path|
      next unless File.file?(path)
      relative = path.sub(/\A#{Regexp.escape(@local_hls_dir)}\/?/, "")
      put_object(path, "#{prefix}#{relative}")
    end
    public_url("#{prefix}master.m3u8")
  end

  def purge
    client.list_objects_v2(bucket: bucket_name, prefix: prefix).contents.each_slice(1000) do |batch|
      client.delete_objects(
        bucket: bucket_name,
        delete: { objects: batch.map { |o| { key: o.key } } }
      )
    end
  end

  private

  # Random playback_key makes the prefix unguessable, so the public bucket policy
  # doesn't let anyone enumerate other tasks' output by walking sequential ids
  def prefix
    "dubbing/#{@task.id}-#{@task.playback_key}/hls/"
  end

  def put_object(local_path, key)
    File.open(local_path, "rb") do |body|
      client.put_object(
        bucket: bucket_name,
        key: key,
        body: body,
        content_type: CONTENT_TYPES[File.extname(local_path)] || "application/octet-stream"
      )
    end
  end

  def public_url(key)
    "#{endpoint.chomp('/')}/#{bucket_name}/#{key}"
  end

  def client
    @client ||= Aws::S3::Client.new(
      endpoint: endpoint,
      region: Settings.ibmcos.region,
      access_key_id: Settings.ibmcos.access_key_id,
      secret_access_key: Settings.ibmcos.secret_access_key,
      force_path_style: true
    )
  end

  def endpoint
    Settings.dubbing_hls_endpoint
  end

  def bucket_name
    Settings.dubbing_hls_bucket
  end
end
