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
      batch_size = 20
      batch_files = []

      begin
        # Process chunks in batches
        chunks.each_slice(batch_size).with_index do |batch, batch_index|
          batch_output = Tempfile.new([ "batch_#{batch_index}", ".mp4" ])
          batch_files << batch_output

          command = [ "ffmpeg", "-y" ]

          # Add all inputs
          batch.each do |chunk|
            command += [ "-loop", "1", "-i", chunk["image_url"] ]
          end
          batch.each do |chunk|
            command += [ "-i", chunk["audio_url"] ]
          end

          # Build filter_complex - pair each video with audio to match durations
          filter_parts = []
          concat_inputs = []

          batch.length.times do |i|
            video_input = i
            audio_input = batch.length + i

            # Use concat with n=1 to pair video with audio (this handles shortest automatically)
            filter_parts << "[#{video_input}:v]fps=30,format=yuv420p[v#{i}]"
            filter_parts << "[v#{i}][#{audio_input}:a]concat=n=1:v=1:a=1[v#{i}out][a#{i}out]"
            concat_inputs << "[v#{i}out][a#{i}out]"
          end

          # Concat all paired segments
          filter_parts << "#{concat_inputs.join('')}concat=n=#{batch.length}:v=1:a=1[vout][aout]"

          command += [
            "-filter_complex", filter_parts.join(";"),
            "-map", "[vout]", "-map", "[aout]",
            "-c:v", "av1_nvenc",
            "-c:a", "aac",
            batch_output.path
          ]

          _stdout, stderr, status = Open3.capture3(*command)
          raise "FFmpeg batch processing failed: #{stderr}" unless status.success?
        end

        # Concatenate all batches
        output_file = Tempfile.new([ "output", ".mp4" ])
        concat_file = Tempfile.new([ "concat", ".txt" ])

        batch_files.each { |f| concat_file.write("file '#{f.path}'\n") }
        concat_file.close

        concat_command = [
          "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_file.path,
          "-c", "copy", output_file.path
        ]

        _stdout, stderr, status = Open3.capture3(*concat_command)
        raise "FFmpeg concatenation failed: #{stderr}" unless status.success?

        video_file_attachment = video.video_file
        File.open(output_file.path, "rb") do |file|
          video_file_attachment.attach(io: file, filename: "video_#{video.id}.mp4")
        end

      ensure
        batch_files.each(&:unlink)
        output_file&.unlink
        concat_file&.unlink
      end
    end
  end
end
