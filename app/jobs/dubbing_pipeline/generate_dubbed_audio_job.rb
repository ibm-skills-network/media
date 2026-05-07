module DubbingPipeline
  class GenerateDubbedAudioJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s
      
      tts_files = []
      task.segments.each_with_index do |seg, i|
        next if seg["translated_text"].blank?

        voice_id = task.voice_for(seg["speaker"])

        response = Faraday.new.post("https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}") do |req|
          req.headers["xi-api-key"] = ENV["ELEVENLABS_API_KEY"]
          req.headers["Content-Type"] = "application/json"
          req.body = {
            text: seg["translated_text"],
            model_id: "eleven_multilingual_v2",
            output_format: "mp3_44100_128"
            }.to_json
        end

        raise "ElevenLabs failed for segment #{i}" unless response.success?

        clip_path = File.join(output_dir, "tts_#{i}.mp3")
        File.binwrite(clip_path, response.body)
        tts_files << { index: i, path: clip_path }
      end

      stdout, stderr, status = Open3.capture3(
      "python3", Rails.root.join("script/dubbing/mix_dubbed_audio.py").to_s,
      "--segments", task.segments.to_json,
      "--tts-files", tts_files.to_json,
      "--background-path", task.background_path,
      "--output-dir", output_dir
      )
      
      raise "Audio mixing failed: #{stderr}" unless status.success?

      dubbed_audio_path = File.join(output_dir, "dubbed.mp3")
      task.update!(dubbed_audio_path: dubbed_audio_path)

      DubbingPipeline::CreateDubbedVideoJob.perform_later(task_id)



    end
  end
end
