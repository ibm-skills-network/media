module DubbingPipeline
  class GenerateDubbedAudioJob < ApplicationJob
    queue_as :low

    MAX_GAP_S = 1.0
    MAX_MERGED_DURATION_S = 15.0
    MAX_RETRANSLATE_ATTEMPTS = 2
    MAX_SPEED = 1.35
    SLOT_PAD_S = 0.5

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s

      merged_segments = merge_segments_for_tts(task.segments)
      total_s = probe_duration_seconds(task.background_path)

      tts_files = []
      merged_segments.each_with_index do |seg, i|
        next if seg["translated_text"].to_s.strip.empty?

        voice_id = task.voice_for(seg["speaker"])
        sanitized_text = sanitize_for_tts(seg["translated_text"])
        slot_s = compute_slot_seconds(merged_segments, i, total_s)
        next if slot_s <= 0.1

        clip_path, final_text = generate_tts_with_retranslation(
          text: sanitized_text,
          original_text: seg["text"],
          voice_id: voice_id,
          voice_settings: task.voice_settings_for(seg["prosody"]),
          slot_s: slot_s,
          target_lang: task.language,
          output_dir: output_dir,
          index: i
        )

        merged_segments[i]["translated_text"] = final_text
        tts_files << { index: i, path: clip_path }
      end

      task.update!(segments: merged_segments, subtitle_segments: merged_segments)

      segments_file = File.join(output_dir, "mix_segments.json")
      tts_files_path = File.join(output_dir, "mix_tts_files.json")
      File.write(segments_file, merged_segments.to_json)
      File.write(tts_files_path, tts_files.to_json)

      _stdout, stderr, status = Open3.capture3(
        "python3", Rails.root.join("script/dubbing/mix_dubbed_audio.py").to_s,
        "--segments-file", segments_file,
        "--tts-files-file", tts_files_path,
        "--background-path", task.background_path,
        "--vocals-path", task.vocals_path,
        "--original-audio-path", task.audio_path,
        "--output-dir", output_dir
      )

      raise "Audio mixing failed: #{stderr}" unless status.success?

      dubbed_audio_path = File.join(output_dir, "dubbed.mp3")
      task.update!(dubbed_audio_path: dubbed_audio_path)

      DubbingPipeline::CreateDubbedVideoJob.perform_later(task_id)
    end

    private

    def merge_segments_for_tts(segments)
      return [] if segments.empty?

      merged = []
      current = nil

      segments.each do |seg|
        if current.nil?
          current = seg.dup
          next
        end

        gap = seg["start"] - current["end"]
        merged_duration = seg["end"] - current["start"]
        same_speaker = seg["speaker"] == current["speaker"]
        ends_with_sentence = current["translated_text"].to_s.rstrip[-1, 1].to_s.match?(/[.!?;:]/)

        if same_speaker && gap <= MAX_GAP_S && merged_duration <= MAX_MERGED_DURATION_S && !ends_with_sentence
          current["end"] = seg["end"]
          current["text"] = "#{current["text"]} #{seg["text"]}"
          current["translated_text"] = "#{current["translated_text"]} #{seg["translated_text"]}".strip
        else
          merged << current
          current = seg.dup
        end
      end

      merged << current if current
      merged
    end

    def sanitize_for_tts(text)
      text.to_s
          .gsub(/\s*[—–]\s*/, ", ")
          .gsub(/[‑]/, " ")
          .gsub(/,\s*,/, ",")
          .gsub(/\s{2,}/, " ")
          .strip
    end

    # Slot bounds match mix_dubbed_audio.py: from this segment's start to min(next clip's
    # segment start, this segment's end + SLOT_PAD_S). Capping at segment end means long
    # pauses after sentences don't inflate the slot.
    def compute_slot_seconds(segments, i, total_s)
      seg_start = segments[i]["start"]
      seg_end = segments[i]["end"]
      next_start = segments[(i + 1)..]&.find { |s| !s["translated_text"].to_s.strip.empty? }&.dig("start") || total_s
      slot_end = [ next_start, seg_end + SLOT_PAD_S ].min
      slot_end - seg_start
    end

    def probe_duration_seconds(path)
      out, _err, status = Open3.capture3(
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        path
      )
      raise "ffprobe failed for #{path}" unless status.success?
      out.strip.to_f
    end

    def generate_tts_with_retranslation(text:, original_text:, voice_id:, voice_settings:, slot_s:, target_lang:, output_dir:, index:)
      current_text = text
      clip_path = File.join(output_dir, "tts_#{index}.mp3")
      slot_ms = (slot_s * 1000).to_i

      MAX_RETRANSLATE_ATTEMPTS.times do
        write_tts_clip(current_text, voice_id, clip_path, voice_settings)
        clip_ms = tts_duration_ms(clip_path)

        # If the clip fits, or speedup alone can rescue it, we're done — Python handles the speedup.
        return [ clip_path, current_text ] if clip_ms <= slot_ms || (clip_ms.to_f / slot_ms) <= MAX_SPEED

        current_text = retranslate_shorter(current_text, original_text, slot_s, target_lang)
      end

      # Final attempt with the last retranslation; Python will speed-up or trim if still long
      write_tts_clip(current_text, voice_id, clip_path, voice_settings)
      [ clip_path, current_text ]
    end

    def write_tts_clip(text, voice_id, clip_path, voice_settings)
      conn = Faraday.new do |f|
        f.options.timeout = 120
        f.options.open_timeout = 10
      end
      response = conn.post("https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}") do |req|
        req.headers["xi-api-key"] = ENV["ELEVENLABS_API_KEY"]
        req.headers["Content-Type"] = "application/json"
        req.body = {
          text: text,
          model_id: "eleven_multilingual_v2",
          output_format: "mp3_44100_128",
          voice_settings: voice_settings
        }.to_json
      end
      raise "ElevenLabs failed: #{response.status} #{response.body}" unless response.success?
      File.binwrite(clip_path, response.body)
    end

    def tts_duration_ms(clip_path)
      out, _err, status = Open3.capture3(
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        clip_path
      )
      raise "ffprobe failed for #{clip_path}" unless status.success?
      (out.strip.to_f * 1000).to_i
    end

    def retranslate_shorter(text, original_text, slot_s, target_lang)
      max_syllables = (slot_s * 4).to_i
      conn = Faraday.new do |f|
        f.options.timeout = 60
        f.options.open_timeout = 10
      end
      response = conn.post("https://api.openai.com/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: "gpt-5-mini",
          messages: [
            {
              role: "system",
              content: "You are a dubbing translator. The previous #{target_lang} translation is too long for the available time (#{slot_s.round(1)}s). Produce a SHORTER translation (max ~#{max_syllables} syllables) that preserves the core meaning. Return ONLY the translated text."
            },
            {
              role: "user",
              content: "Original: #{original_text}\nToo-long translation: #{text}"
            }
          ]
        }.to_json
      end
      raise "GPT retranslate failed: #{response.status} #{response.body}" unless response.success?

      JSON.parse(response.body)["choices"][0]["message"]["content"].strip
    end
  end
end
