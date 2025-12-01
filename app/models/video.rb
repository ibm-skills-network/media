class Video < ApplicationRecord
  has_many :transcoding_processes, class_name: "Videos::TranscodingProcess", dependent: :destroy

  VIDEO_TYPES = [ "video/mp4", "video/webm", "video/quicktime" ].freeze

  validate :validate_external_video_link

  def create_transcoding_process!(transcoding_profiles)
    max_quality = Videos::TranscodingProcess.determine_max_quality(external_video_link)
    max_quality_value = Videos::TranscodingProfile.labels[max_quality]

    transcoding_profiles.each do |transcoding_profile|
      target_quality_value = Videos::TranscodingProfile.labels[transcoding_profile.label]

      if max_quality_value < target_quality_value
        transcoding_processes.create!(transcoding_profile: transcoding_profile, status: :unavailable)
      else
        transcoding_processes.create!(transcoding_profile: transcoding_profile)
      end
    end
  end

  def transcode_video!
    return if transcoding_processes.empty?

    processes_to_transcode = transcoding_processes.reject { |tp| tp.success? || tp.unavailable? }
    return if processes_to_transcode.empty?

    processes_to_transcode.each(&:processing!)

    command = [
      "ffmpeg",
      "-y",
      "-hwaccel", "cuda",
      "-hwaccel_output_format", "cuda",
      "-i", external_video_link
    ]

    temp_outputs = {}
    filter_complex = []

    # Build temp files and scaling filters
    # Note: We scale directly from [0:v] for each output to keep everything on GPU
    processes_to_transcode.each_with_index do |transcoding_process, index|
      temp_file = Tempfile.new([ "#{transcoding_process.id}_output", ".mp4" ])
      temp_file.close
      temp_outputs[transcoding_process] = temp_file

      # Scale directly from input - FFmpeg will handle multiple reads efficiently
      filter_complex << "[0:v]scale_cuda=min(#{transcoding_process.transcoding_profile.width}\\,iw):min(#{transcoding_process.transcoding_profile.height}\\,ih)[v#{index}]"
    end

    # Add the filter_complex option
    command += [ "-filter_complex", filter_complex.join(";") ]

    # Add each output with its mapped stream
    processes_to_transcode.each_with_index do |transcoding_process, index|
      temp_file = temp_outputs[transcoding_process]
      command += [
        "-map", "[v#{index}]",
        "-map", "0:a?",
        "-c:v", transcoding_process.transcoding_profile.codec,
        "-b:v", transcoding_process.transcoding_profile.bitrate_string,
        "-preset", "p4",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ac", "2",
        temp_file.path
      ]
    end

    _stdout, stderr, status = Open3.capture3(*command)

    if status.success?
      temp_outputs.each do |transcoding_process, temp_file|
        if File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          File.open(temp_file.path, "rb") do |file|
            transcoding_process.video_file.attach(io: file, filename: "transcoded_#{transcoding_process.id}_output.mp4")
          end
          transcoding_process.success!
        else
          transcoding_process.failed!
        end
      end
    else
      processes_to_transcode.each { |tp| tp.failed! unless tp.success? || tp.unavailable? }
      raise "FFmpeg encoding failed: #{stderr}"
    end

  ensure
    temp_outputs&.each_value(&:unlink)
  end

  private

  def validate_external_video_link
    return unless external_video_link.present?

    unless VIDEO_TYPES.include?(Ffmpeg::Video.mime_type(external_video_link))
      errors.add(:external_video_link, "must be a valid video file (mp4, webm, or mov)")
    end
  end
end
