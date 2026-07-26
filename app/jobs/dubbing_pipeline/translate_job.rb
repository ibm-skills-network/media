module DubbingPipeline
  class TranslateJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 15
    CONTEXT_OVERLAP = 2
    MAX_CONCURRENCY = 5
    BATCH_TIMEOUT_S = 600
    MAX_BATCH_RETRIES = 3
    MAX_MISSING_RETRIES = 2

    # Per-language budgeting. Each entry is:
    #   [ pace, unit, expansion ]
    #   pace      TTS words/sec (or CJK chars/sec) at the voice's natural, unhurried pace.
    #             This is the real measured output pace, NOT shaded down: the budget is
    #             now a two-sided band, so headroom comes from the hard-cap clamp below,
    #             not from a deliberately-low rate that starved faithful lines.
    #   unit      "words" or, for CJK, "characters" (what we count in the target text).
    #   expansion how much longer the target runs than the English source, in target
    #             units per English word. Words->words for most languages; for CJK it
    #             converts English words into target characters. Used to FLOOR the budget
    #             at the length a faithful translation actually needs, so a line that fit
    #             its time in English is never forced to compress.
    LENGTH_BUDGET_RATES = {
      "Spanish"    => [ 2.9, "words",      1.25 ],
      "Italian"    => [ 2.9, "words",      1.20 ],
      "Portuguese" => [ 2.9, "words",      1.25 ],
      "French"     => [ 3.0, "words",      1.28 ],
      "German"     => [ 2.6, "words",      1.10 ],
      "Japanese"   => [ 7.2, "characters", 1.40 ],
      "Chinese"    => [ 4.8, "characters", 1.40 ]
    }.freeze
    DEFAULT_BUDGET_RATE = [ 2.9, "words", 1.0 ].freeze

    # How far a clip may exceed the comfortable-pace budget and still be accepted
    # without audible speedup. Mirrors GenerateDubbedAudioJob::COMFORT_SPEED so the
    # translator never asks for more than the mixer will take cleanly.
    COMFORT_SPEED = 1.15
    MIN_WORD_BUDGET = 3

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg.dig("args", 0, "arguments", 0))
      next if task.nil? || task.terminal?
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.terminal?

      segments = task.segments

      batches = build_batches(segments)
      translations = translate_batches_in_parallel(batches, segments, task.language)

      # Re-request lines that dropped out of an otherwise successful batch before
      # falling back to the original audio
      retranslate_missing_segments(translations, segments, task.language)

      missing = []
      segments.each_with_index do |seg, i|
        translated = translations[i]
        if translated.to_s.strip.empty?
          missing << i
          # Keep the source text for subtitles, but flag is so 
          # GenerateDubbedAudioJob splices the original audio in rather than voicing
          # untranslated English.
          seg["translated_text"] = seg["text"]
          seg["use_original_audio"] = true
        else
          seg["translated_text"] = translated
          seg.delete("use_original_audio")
        end
      end
      if missing.any?
        Rails.logger.warn("[TranslateJob] #{missing.size} segments will use original audio: #{missing.first(10).inspect}")
        if missing.size > segments.size / 10
          raise "Translation incomplete: #{missing.size}/#{segments.size} segments missing translations"
        end
      end

      # Snapshot into subtitle_segments before GenerateDubbedAudioJob merges
      # adjacent segments for TTS, subtitles need the original granularity
      task.update!(segments: segments, subtitle_segments: segments)
      DubbingPipeline::GenerateDubbedAudioJob.perform_later(task_id)
    end

    private

    # Re-request segments still missing a translation, mutating `translations` in
    # place. Missing lines are grouped into contiguous runs so each retry reads
    # like a normal batch with preceding context.
    def retranslate_missing_segments(translations, segments, target_lang)
      MAX_MISSING_RETRIES.times do |attempt|
        missing = (0...segments.length).reject { |i| translations[i].to_s.strip.present? }
        return if missing.empty?

        Rails.logger.warn(
          "[TranslateJob] retry #{attempt + 1}/#{MAX_MISSING_RETRIES} for " \
          "#{missing.size} missing segments: #{missing.first(10).inspect}"
        )

        contiguous_runs(missing).each do |run|
          batch = {
            context_range: ([ run.first - CONTEXT_OVERLAP, 0 ].max...run.first),
            translate_range: (run.first..run.last)
          }
          recovered =
            begin
              translate_batch_with_retry(batch, segments, target_lang)
            rescue => e
              Rails.logger.error("[TranslateJob] missing-segment retry failed: #{e.class}: #{e.message}")
              {}
            end
          # only fill real gaps, never overwrite a line we already have
          recovered.each { |i, text| translations[i] ||= text if text.to_s.strip.present? }
        end
      end
    end

    # [1, 2, 3, 7, 8, 11] => [1..3, 7..8, 11..11]
    def contiguous_runs(indices)
      indices.slice_when { |prev, cur| cur != prev + 1 }.map { |run| run.first..run.last }
    end

    # each batch carries a few preceding segments as read-only context, not for
    # translation, just so GPT keeps tone and pronouns consistent across batches
    def build_batches(segments)
      batches = []
      i = 0
      while i < segments.length
        context_start = [ i - CONTEXT_OVERLAP, 0 ].max
        batch_end = [ i + BATCH_SIZE, segments.length ].min
        batches << {
          context_range: (context_start...i),
          translate_range: (i...batch_end)
        }
        i = batch_end
      end
      batches
    end

    def translate_batches_in_parallel(batches, segments, target_lang)
      pool = Concurrent::FixedThreadPool.new(MAX_CONCURRENCY)
      begin
        futures = batches.map do |batch|
          Concurrent::Promises.future_on(pool) { translate_batch_with_retry(batch, segments, target_lang) }
        end

        translations = {}
        failure_count = 0
        futures.each_with_index do |future, idx|
          result = future.value!(MAX_BATCH_RETRIES * BATCH_TIMEOUT_S + 100)
          translations.merge!(result) if result.is_a?(Hash)
        rescue => e
          Rails.logger.error("[TranslateJob] batch #{idx} failed: #{e.class}: #{e.message}")
          failure_count += 1
        end

        if failure_count.positive?
          Rails.logger.error("[TranslateJob] #{failure_count}/#{batches.size} batches failed")
        end

        translations
      ensure
        pool.shutdown
        pool.wait_for_termination(30) || pool.kill
      end
    end

    def translate_batch_with_retry(batch, segments, target_lang)
      attempt = 0
      begin
        attempt += 1
        translate_batch(batch, segments, target_lang)
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed
        raise if attempt >= MAX_BATCH_RETRIES
        sleep(2**attempt)
        retry
      rescue RuntimeError => e
        raise unless e.message =~ /\b(429|5\d\d)\b/
        raise if attempt >= MAX_BATCH_RETRIES
        sleep(2**attempt)
        retry
      end
    end

    def translate_batch(batch, segments, target_lang)
      lines = []
      batch[:context_range].each do |i|
        lines << "[CONTEXT #{i}] #{segments[i]["text"]}"
      end
      batch[:translate_range].each do |i|
        seg = segments[i]
        duration = (seg["end"] - seg["start"]).round(1)
        lines << "[#{i}|#{duration}s|#{length_budget(duration, seg["text"], target_lang)}] #{seg["text"]}"
      end
      payload_text = lines.join("\n")

      conn = Faraday.new do |f|
        f.options.timeout = BATCH_TIMEOUT_S
        f.options.open_timeout = 10
      end
      response = conn.post("https://api.openai.com/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV["OPENAI_API_KEY"]}"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: "gpt-5-mini",
          messages: [
            { role: "system", content: system_prompt(target_lang) },
            { role: "user", content: payload_text }
          ]
        }.to_json
      end

      raise "GPT translate failed: HTTP #{response.status}" unless response.success?

      result = JSON.parse(response.body)["choices"][0]["message"]["content"].to_s

      parsed = {}
      result.split("\n").each do |line|
        # Tolerate whatever tag shape the model echoes back ([3|2.5s], [3|2.5s|max 8 words], ...)
        match = line.strip.match(/\[(\d+)\|[^\]]*\]\s*(.+)/)
        next unless match
        idx = match[1].to_i
        parsed[idx] = match[2].strip if batch[:translate_range].include?(idx)
      end
      parsed
    end

    # A two-sided length band for the line, so the model has both a target to
    # FILL and a ceiling not to exceed. Emitted as "aim ~X, max Y <unit>".
    #
    #   hard_cap  the most the line may run and still fit its slot without audible
    #             speedup (comfortable pace x COMFORT_SPEED x duration).
    #   want      the length a FAITHFUL translation actually needs, from the source's
    #             own word count times the language's expansion. This floors the aim so
    #             a line that already fit its time in English is never told to compress.
    #   aim       want, clamped into [comfortable pace target, hard_cap]. The aim never
    #             dips below the comfortable-pace target (kills under-run) and never
    #             exceeds hard_cap (kills over-run).
    #
    # Before, the budget was a single `max N` sitting ~10% under real pace, so the
    # model shrank every line toward it and the dub finished early. The floor is the fix.
    def length_budget(duration, source_text, target_lang)
      rate, unit, expansion = LENGTH_BUDGET_RATES.fetch(target_lang, DEFAULT_BUDGET_RATE)

      hard_cap = [ (duration * rate * COMFORT_SPEED).floor, MIN_WORD_BUDGET ].max
      comfortable = [ (duration * rate).floor, MIN_WORD_BUDGET ].max

      source_words = source_text.to_s.split.length
      want = (source_words * expansion).round

      aim = want.clamp(comfortable, hard_cap)
      "aim ~#{aim}, max #{hard_cap} #{unit}"
    end

    def system_prompt(target_lang)
      <<~PROMPT
        You are a professional dubbing translator for film/TV. Translate this transcript to #{target_lang}.

        The input may include [CONTEXT N] lines showing the original-language segments immediately before this batch. Use these only for tone/term/pronoun consistency. DO NOT translate or output anything for [CONTEXT N] lines.

        Translate only the lines formatted as [index|duration|budget].

        Every translation is spoken aloud by a TTS voice at a natural pace, and the audio should fill about as much time as the original line took. Each line carries a length band "aim ~X, max Y": X is the length that fills the slot naturally, Y is the hard ceiling. A line that runs OVER Y gets mechanically sped up and sounds rushed; a line that comes in far UNDER X leaves dead air and the dub drifts out of sync with the speaker. Land in the band.

        LENGTH RULES (most important):
        1. Translate the line FAITHFULLY and COMPLETELY first. Aim for ~X in the band; you may go up to Y but never past it. Do NOT shrink a faithful translation below the aim just to be safe. The aim is where you want to be, not a limit to beat.
        2. Only compress when the faithful translation would exceed Y. When you must compress, drop fillers, hedges, and redundancy while keeping the message. NEVER cut content a learner acts on: negations, numbers, ordinals ("first", "second"), qualifiers like "again" or "only", or full technique names (keep "chain of thought prompting", not just "chain of thought").
        3. If the faithful translation lands well under the aim, that is fine, DON'T pad with filler, but don't compress it further either. Prefer the complete, natural phrasing over a clipped one.
        4. #{target_lang} may need more words or syllables than English. The band already accounts for this, so translate naturally and trust the band; only tighten if you would exceed Y.

        Compress ONLY when over the ceiling (shown English to Spanish, do the equivalent in #{target_lang}):
        [3|3.8s|aim ~9, max 11 words] So, what we're going to do now is take a look at zero shot prompting.
        FAITHFUL, fits (9 words): Ahora vamos a echar un vistazo al zero shot prompting.
        OVER-COMPRESSED, don't do this (6 words): Ahora veremos el zero shot prompting.

        LISTS AND ENUMERATIONS:
        5. When the speaker enumerates items or steps, KEEP every item and KEEP the ordinals ("first / second / third", "one / two / three"). These are the last thing to compress, not the first.
        6. Separate list items with sentence-final punctuation (a period, or a semicolon) rather than only commas, so the voice pauses between items instead of rushing them together. Example: "First, load the data. Second, clean it. Third, train the model." NOT "First load the data, second clean it, third train the model."
        7. Keep parallel grammatical structure across items so the enumeration is audible as a list.

        STYLE RULES:
        8. Produce natural, spoken-style translations. NOT literal word-by-word.
        9. Prefer contractions and colloquial phrasing over formal/written style.
        10. Preserve the emotional tone and intent, but freely rephrase for natural flow.
        11. NEVER skip a line or leave it empty.
        12. NEVER use em-dashes, en-dashes, or hyphens as parenthetical separators. Use commas instead. The text will be read aloud by TTS.
        13. For technical terms with hyphens (like 'zero-shot'), write them as spoken words (like 'zero shot').

        Return translated lines in same format, one per input line:
        [0|2.5s] Translation here
        [1|3.0s] Next translation
      PROMPT
    end
  end
end
