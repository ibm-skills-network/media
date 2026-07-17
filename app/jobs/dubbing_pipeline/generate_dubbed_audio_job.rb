module DubbingPipeline
  class GenerateDubbedAudioJob < ApplicationJob
    queue_as :low

    MAX_GAP_S = 1.0
    MAX_MERGED_DURATION_S = 15.0
    MAX_RETRANSLATE_ATTEMPTS = 2
    MAX_SPEED = 1.35
    # Above this speedup, retranslating is worth trying before accepting the clip
    COMFORT_SPEED = 1.15
    SLOT_PAD_S = 0.5

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg.dig("args", 0, "arguments", 0))
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      DubbingWorkspace.with("#{task_id}-mix") do |ws|
        audio_path = ws.fetch(task.audio, "audio.wav")
        vocals_path = ws.fetch(task.vocals, "vocals.wav")
        background_path = ws.fetch(task.background, "background.wav")

        merged_segments = merge_segments_for_tts(task.segments)
        total_s = DubbingFfprobe.duration_seconds(background_path)

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
            output_dir: ws.dir,
            index: i
          )

          merged_segments[i]["retranslated"] = final_text != sanitized_text
          merged_segments[i]["translated_text"] = final_text
          tts_files << { index: i, path: clip_path }
        end

        subtitle_segments = rebuild_subtitle_segments(
          task.subtitle_segments, merged_segments, task.segments.length
        )
        merged_segments.each { |seg| seg.delete("source_range"); seg.delete("retranslated") }

        segments_file = ws.path("mix_segments.json")
        tts_files_path = ws.path("mix_tts_files.json")
        File.write(segments_file, merged_segments.to_json)
        File.write(tts_files_path, tts_files.to_json)

        _stdout, stderr, status = Open3.capture3(
          "python3", Rails.root.join("script/dubbing/mix_dubbed_audio.py").to_s,
          "--segments-file", segments_file,
          "--tts-files-file", tts_files_path,
          "--background-path", background_path,
          "--vocals-path", vocals_path,
          "--original-audio-path", audio_path,
          "--output-dir", ws.dir
        )

        raise "Audio mixing failed: #{stderr}" unless status.success?

        # Persist only after mixing succeeds, otherwise a retry would see half-merged state
        task.update!(segments: merged_segments, subtitle_segments: subtitle_segments)
        ws.attach(task.dubbed_audio, "dubbed.m4a", content_type: "audio/mp4")
      end

      DubbingPipeline::CreateDubbedVideoJob.perform_later(task_id)
    end

    private

    # Combine adjacent same-speaker segments so TTS gets longer phrases to voice naturally
    def merge_segments_for_tts(segments)
      return [] if segments.empty?

      merged = []
      current = nil

      segments.each_with_index do |seg, idx|
        if current.nil?
          current = seg.dup
          current["source_range"] = [ idx, idx ]
          next
        end

        gap = seg["start"] - current["end"]
        merged_duration = seg["end"] - current["start"]
        same_speaker = seg["speaker"] == current["speaker"]
        # Don't merge across sentence boundaries, TTS needs the pause
        ends_with_sentence = current["translated_text"].to_s.rstrip[-1, 1].to_s.match?(/[.!?;:]/)

        if same_speaker && gap <= MAX_GAP_S && merged_duration <= MAX_MERGED_DURATION_S && !ends_with_sentence
          current["end"] = seg["end"]
          current["text"] = "#{current["text"]} #{seg["text"]}"
          current["translated_text"] = "#{current["translated_text"]} #{seg["translated_text"]}".strip
          current["source_range"][1] = idx
        else
          merged << current
          current = seg.dup
          current["source_range"] = [ idx, idx ]
        end
      end

      merged << current if current
      merged
    end

    # The subtitle snapshot predates retranslation, so it can show text the dub
    # no longer speaks. Collapse each retranslated range into one cue with the
    # spoken text; untouched cues keep their original timing
    def rebuild_subtitle_segments(subtitles, merged_segments, source_count)
      return subtitles if subtitles.blank?

      retranslated = merged_segments.select { |seg| seg["retranslated"] }
      return subtitles if retranslated.empty?

      # A snapshot of a different length means source_range indices don't line up
      if subtitles.length != source_count
        Rails.logger.warn(
          "[GenerateDubbedAudioJob] subtitle snapshot has #{subtitles.length} cues, " \
          "expected #{source_count}; leaving subtitles unchanged"
        )
        return subtitles
      end

      replacements = retranslated.index_by { |seg| seg["source_range"].first }

      rebuilt = []
      i = 0
      while i < subtitles.length
        if (seg = replacements[i])
          rebuilt << seg.except("source_range", "retranslated")
          i = seg["source_range"].last + 1
        else
          rebuilt << subtitles[i]
          i += 1
        end
      end
      rebuilt
    end

    def sanitize_for_tts(text)
      text.to_s
          .gsub(/\s*[—–]\s*/, ", ")
          .gsub(/[‑]/, " ")
          .gsub(/,\s*,/, ",")
          .gsub(/\s{2,}/, " ")
          .strip
    end

    def compute_slot_seconds(segments, i, total_s)
      seg_start = segments[i]["start"]
      seg_end = segments[i]["end"]
      next_start = segments[(i + 1)..]&.find { |s| !s["translated_text"].to_s.strip.empty? }&.dig("start") || total_s
      slot_end = [ next_start, seg_end + SLOT_PAD_S ].min
      slot_end - seg_start
    end

    def generate_tts_with_retranslation(text:, original_text:, voice_id:, voice_settings:, slot_s:, target_lang:, output_dir:, index:)
      current_text = text
      clip_path = File.join(output_dir, "tts_#{index}.mp3")
      best_path = File.join(output_dir, "tts_#{index}_best.mp3")
      slot_ms = (slot_s * 1000).to_i
      best = nil

      (MAX_RETRANSLATE_ATTEMPTS + 1).times do |attempt|
        write_tts_clip(current_text, voice_id, clip_path, voice_settings)
        clip_ms = (DubbingFfprobe.duration_seconds(clip_path) * 1000).to_i

        return [ clip_path, current_text ] if clip_ms <= slot_ms * COMFORT_SPEED

        # A retranslation isn't guaranteed to come out shorter
        if best.nil? || clip_ms < best[:clip_ms]
          FileUtils.cp(clip_path, best_path)
          best = { clip_ms: clip_ms, text: current_text }
        end

        break if attempt == MAX_RETRANSLATE_ATTEMPTS
        current_text = retranslate_shorter(current_text, original_text, clip_ms / 1000.0, slot_s, target_lang)
      end

      # Nothing fit: keep the shortest attempt, Python speeds it up or trims
      Rails.logger.warn(
        "[GenerateDubbedAudioJob] segment #{index} still #{(best[:clip_ms] / 1000.0).round(1)}s " \
        "for a #{slot_s.round(1)}s slot after #{MAX_RETRANSLATE_ATTEMPTS} retranslations"
      )
      FileUtils.mv(best_path, clip_path)
      [ clip_path, best[:text] ]
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
      raise "ElevenLabs failed: HTTP #{response.status}" unless response.success?
      File.binwrite(clip_path, response.body)
    end

    def retranslate_shorter(text, original_text, clip_s, slot_s, target_lang)
      # The measured clip/slot ratio converts directly into a word budget
      current_words = text.split.length
      target_words = [ (current_words * slot_s / clip_s).floor, 3 ].max
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
              content: <<~PROMPT
                You are a dubbing translator. The previous #{target_lang} translation was synthesized to speech and the audio came out too long: it takes #{clip_s.round(1)}s to speak but only #{slot_s.round(1)}s is available. Rewrite it in AT MOST #{target_words} words (it currently has #{current_words}) while preserving the speaker's intent. Shorter than #{target_words} words is even better.

                Prefer:
                  - Stronger single verbs over compound constructions
                  - Dropping fillers, hedges, and redundant qualifiers ("really", "actually", "you know")
                  - Keeping proper nouns, numbers, and key terms intact

                Avoid:
                  - Amputating meaningful content — compress, don't truncate
                  - Dropping words the listener acts on: negations, numbers, qualifiers like "again", "only", "first"
                  - Truncating technique or product names (keep "chain of thought prompting" whole)
                  - Changing the emotional tone or register
                  - Em-dashes, en-dashes, or hyphens as separators (text is read aloud by TTS)

                Here is the kind of compression to perform (shown in English; apply equivalently in #{target_lang}):

                Verbose: "So, what we're going to do is take a look at zero-shot prompting."
                Tighter: "We'll examine zero-shot prompting."

                Verbose: "It's really, really important that you understand this before we continue."
                Tighter: "It's vital to grasp this first."

                Verbose: "The reason this matters is because it directly affects performance."
                Tighter: "This directly affects performance."

                Return ONLY the tighter #{target_lang} translation. No quotes, no commentary, no language label.
              PROMPT
            },
            {
              role: "user",
              content: "Original: #{original_text}\nToo-long translation: #{text}"
            }
          ]
        }.to_json
      end
      raise "GPT retranslate failed: HTTP #{response.status}" unless response.success?

      JSON.parse(response.body)["choices"][0]["message"]["content"].strip
    end
  end
end
