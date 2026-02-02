class Video < ApplicationRecord
  has_one_attached :video_file
  has_many :transcoding_tasks, class_name: "Videos::TranscodingTask", dependent: :destroy

  VIDEO_TYPES = [ "video/mp4", "video/webm", "video/quicktime" ].freeze

  validate :validate_video
  validate :only_one_video_source


  def video_source_url
    external_video_link.present? ? external_video_link : video_file.url
  end

  def transcode_video!
    raise "Video source is blank" if video_source_url.blank?

    return if transcoding_tasks.empty?

    processes_to_transcode = transcoding_tasks.reject { |tp| tp.success? || tp.unavailable? }
    return if processes_to_transcode.empty?

    processes_to_transcode.each(&:processing!)

    # Benchmark download speed (discards the data, just for timing)
    download_start = Time.now
    response = Faraday.get(video_source_url)
    download_duration = Time.now - download_start
    download_size_mb = response.body.bytesize / 1_000_000.0
    download_speed = download_duration > 0 ? (download_size_mb / download_duration).round(2) : "N/A"
    Rails.logger.info("[Video#transcode_video!] Download benchmark: #{download_size_mb.round(2)}MB in #{download_duration.round(2)}s (#{download_speed} MB/s)")

    command = [
      "ffmpeg",
      "-y",
      "-hwaccel", "cuda",
      "-hwaccel_output_format", "cuda",
      "-i", video_source_url
    ]

    temp_outputs = {}
    filter_complex = []

    # Build temp files and scaling filters
    # Note: We scale directly from [0:v] for each output to keep everything on GPU
    processes_to_transcode.each_with_index do |transcoding_task, index|
      temp_file = Tempfile.new([ "#{transcoding_task.id}_output", ".mp4" ])
      temp_file.close
      temp_outputs[transcoding_task] = temp_file

      # Scale directly from input - FFmpeg will handle multiple reads efficiently
      filter_complex << "[0:v]scale_cuda=min(#{transcoding_task.transcoding_profile.width}\\,iw):min(#{transcoding_task.transcoding_profile.height}\\,ih)[v#{index}]"
    end

    # Add the filter_complex option
    command += [ "-filter_complex", filter_complex.join(";") ]

    # Add each output with its mapped stream
    processes_to_transcode.each_with_index do |transcoding_task, index|
      temp_file = temp_outputs[transcoding_task]
      command += [
        "-map", "[v#{index}]",
        "-map", "0:a?",
        "-c:v", transcoding_task.transcoding_profile.codec,
        "-b:v", transcoding_task.transcoding_profile.bitrate_string,
        "-preset", "p4",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ac", "2",
        temp_file.path
      ]
    end

    # Track ffmpeg execution time
    ffmpeg_start = Time.now
    _stdout, stderr, status = Open3.capture3(*command)
    ffmpeg_duration = Time.now - ffmpeg_start
    Rails.logger.info("[Video#transcode_video!] FFmpeg command took #{ffmpeg_duration.round(2)}s")

    if status.success?
      temp_outputs.each do |transcoding_task, temp_file|
        if File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          # Track upload time for each transcoded video
          upload_start = Time.now
          File.open(temp_file.path, "rb") do |file|
            transcoding_task.video_file.attach(io: file, filename: "transcoded_#{transcoding_task.id}_output.mp4")
          end
          upload_duration = Time.now - upload_start
          Rails.logger.info("[Video#transcode_video!] Upload for task #{transcoding_task.id} took #{upload_duration.round(2)}s")
          transcoding_task.success!
        else
          transcoding_task.failed!
        end
      end
    else
      processes_to_transcode.each { |tp| tp.failed! unless tp.success? || tp.unavailable? }
      raise "FFmpeg encoding failed: #{stderr}"
    end

  ensure
    temp_outputs&.each_value(&:unlink)
  end

  def max_quality_label
    metadata = Ffmpeg::Video.video_metadata_from_url(external_video_link)

    video_stream = metadata["streams"].find { |stream| stream["width"].present? && stream["height"].present? }

    width = video_stream["width"]
    height = video_stream["height"]

    if height >= 1080 && width >= 1920
      "1080p"
    elsif height >= 720 && width >= 1280
      "720p"
    else
      "480p"
    end
  end

  private

  def validate_video
    if external_video_link.present? && !VIDEO_TYPES.include?(Ffmpeg::Video.mime_type(external_video_link))
      errors.add(:base, "external video link must be a valid video link (mp4, webm, or mov)")
    end

    if video_file.attached? && !VIDEO_TYPES.include?(video_file.blob.content_type)
      errors.add(:base, "video file must be a valid video file (mp4, webm, or mov)")
    end
  end

  def only_one_video_source
    if external_video_link.present? && video_file.attached?
      errors.add(:base, "only one video source can be provided")
    end
  end
end
