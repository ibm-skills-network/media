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

    processes_to_transcode = transcoding_processes.reject(&:success?)
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

    # Split the input stream for multiple outputs
    split_count = processes_to_transcode.length
    if split_count > 1
      split_outputs = (0...split_count).map { |i| "[in#{i}]" }.join
      filter_complex << "[0:v]split_cuda=#{split_count}#{split_outputs}"
    end

    # Build temp files and scaling filters
    processes_to_transcode.each_with_index do |transcoding_process, index|
      temp_file = Tempfile.new([ "#{transcoding_process.id}_output", ".mp4" ])
      temp_file.close
      temp_outputs[transcoding_process] = temp_file

      # Use the split stream input for multiple outputs, or direct input for single output
      input_stream = split_count > 1 ? "[in#{index}]" : "[0:v]"
      filter_complex << "#{input_stream}scale_cuda=min(#{transcoding_process.transcoding_profile.width}\\,iw):min(#{transcoding_process.transcoding_profile.height}\\,ih)[v#{index}]"
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
end
