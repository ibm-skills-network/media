class Video < ApplicationRecord
  has_many :transcoding_processes, class_name: "Videos::Quality::TranscodingProcess", dependent: :destroy

  validates :external_video_link, presence: true

  def create_transcoding_process!(transcoding_profiles)
    transcoding_profiles.each do |transcoding_profile|
      transcoding_processes.create!(transcoding_profile: transcoding_profile)
    end
  end

  def transcode_video!
    return if transcoding_processes.empty?

    transcoding_processes.each { |tp| tp.processing! unless tp.success? }

    command = [
      "ffmpeg",
      "-y",
      "-hwaccel", "cuda",
      "-hwaccel_output_format", "cuda",
      "-i", external_video_link
    ]

    temp_outputs = {}

    transcoding_processes.each do |transcoding_process|
      temp_file = Tempfile.new([ "#{transcoding_process.id}_output", ".mp4" ])
      temp_file.close
      temp_outputs[transcoding_process] = temp_file

      command += [
        "-vf", "scale_cuda=min(#{transcoding_process.transcoding_profile.width},iw):min(#{transcoding_process.transcoding_profile.height},ih)",
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
      transcoding_processes.each { |tp| tp.failed! unless tp.success? || tp.unavailable? }
      raise "FFmpeg encoding failed: #{stderr}"
    end

  ensure
    temp_outputs&.each_value(&:unlink)
  end
end
