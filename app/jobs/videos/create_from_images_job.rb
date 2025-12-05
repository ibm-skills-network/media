require "open-uri"

module Videos
  class CreateFromImagesJob < ApplicationJob
    queue_as :gpu

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
      video = Video.find(msg["args"].first)
      video.update(external_video_link: nil) if video.present?
    end

    def perform(video_id, chunks)
      video = Video.find(video_id)

      temp_files = []
      output_file = Tempfile.new([ "output", ".mp4" ])

      begin
        # Download all images and audio files
        image_files = []
        audio_files = []

        chunks.each_with_index do |chunk, index|
          image_file = Tempfile.new([ "image_#{index}", ".png" ])
          audio_file = Tempfile.new([ "audio_#{index}", ".mp3" ])

          temp_files << image_file << audio_file

          image_file.binmode
          audio_file.binmode
          image_file.write(URI.open(chunk["image_url"]).read)
          audio_file.write(URI.open(chunk["audio_url"]).read)
          image_file.close
          audio_file.close

          image_files << image_file.path
          audio_files << audio_file.path
        end

        # Build ffmpeg command with all inputs and filter complex
        command = [ "ffmpeg", "-y" ]

        # Add all image inputs with loop
        chunks.length.times do |i|
          command += [ "-loop", "1", "-i", image_files[i] ]
        end

        # Add all audio inputs
        chunks.length.times do |i|
          command += [ "-i", audio_files[i] ]
        end

        # Build filter_complex for processing and concatenating
        filter_parts = []
        concat_inputs = []

        chunks.length.times do |i|
          video_input = i
          audio_input = chunks.length + i

          # Scale and pad each video to match the audio duration, then trim to shortest
          filter_parts << "[#{video_input}:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v#{i}]"
          filter_parts << "[#{audio_input}:a]aformat=sample_rates=48000:channel_layouts=stereo[a#{i}]"
          filter_parts << "[v#{i}][a#{i}]concat=n=1:v=1:a=1[v#{i}out][a#{i}out]"
          concat_inputs << "[v#{i}out][a#{i}out]"
        end

        # Concatenate all processed segments
        filter_parts << "#{concat_inputs.join('')}concat=n=#{chunks.length}:v=1:a=1[vout][aout]"

        command += [
          "-filter_complex", filter_parts.join(";"),
          "-map", "[vout]",
          "-map", "[aout]",
          "-c:v", "av1_nvenc",
          "-preset", "p4",
          "-b:v", "5M",
          "-c:a", "aac",
          "-b:a", "192k",
          "-pix_fmt", "yuv420p",
          "-shortest",
          output_file.path
        ]

        _stdout, stderr, status = Open3.capture3(*command)

        unless status.success?
          raise "FFmpeg processing failed: #{stderr}"
        end

        video_file_attachment = video.video_file
        File.open(output_file.path, "rb") do |file|
          video_file_attachment.attach(io: file, filename: "video_#{video.id}.mp4")
        end

      ensure
        temp_files.each(&:unlink)
        output_file.unlink
      end
    end
  end
end
