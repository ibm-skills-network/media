class Video < ApplicationRecord
  has_many :qualities, class_name: "Videos::Quality", dependent: :destroy

  validates :external_video_link, presence: true

  def create_qualities!(transcoding_profiles)
    transcoding_profiles.each do |transcoding_profile|
      qualities.create!(transcoding_profile: transcoding_profile)
    end
  end

  def encode_qualities!
    return if qualities.empty?

    qualities.each { |q| q.processing! unless q.success? }

    command = [
      "ffmpeg",
      "-y",
      "-hwaccel", "cuda",
      "-hwaccel_output_format", "cuda",
      "-i", external_video_link
    ]

    temp_outputs = {}

    qualities.each do |quality|
      temp_file = Tempfile.new([ "#{quality.id}_output", ".mp4" ])
      temp_file.close
      temp_outputs[quality] = temp_file

      command += [
        "-vf", "scale_cuda=min(#{quality.transcoding_profile.width},iw):min(#{quality.transcoding_profile.height},ih)",
        "-c:v", quality.transcoding_profile.codec,
        "-b:v", quality.transcoding_profile.bitrate_string,
        "-preset", "p4",
        "-c:a", "aac",
        "-b:a", "128k",
        "-ac", "2",
        temp_file.path
      ]
    end

    _stdout, stderr, status = Open3.capture3(*command)

    if status.success?
      temp_outputs.each do |quality, temp_file|
        if File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          File.open(temp_file.path, "rb") do |file|
            quality.video_file.attach(io: file, filename: "#{quality.id}_output.mp4")
          end
          quality.success!
        else
          quality.failed!
        end
      end
    else
      qualities.each { |q| q.failed! unless q.success? || q.unavailable? }
      raise "FFmpeg encoding failed: #{stderr}"
    end

  ensure
    temp_outputs&.each_value(&:unlink)
  end
end
