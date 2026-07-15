module DubbingPipeline
  class TranslateJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 15
    CONTEXT_OVERLAP = 2
    MAX_CONCURRENCY = 5
    BATCH_TIMEOUT_S = 600
    MAX_BATCH_RETRIES = 3

    # Speaking pace per language, set ~10% below measured TTS output so
    # budget-compliant lines still fit slower voices. Spanish is calibrated
    # against real eleven_multilingual_v2 output (2.55 words/s, 2026-07);
    # the rest are estimates relative to it. CJK is measured in characters.
    LENGTH_BUDGET_RATES = {
      "Spanish"    => [ 2.3, "words" ],
      "Italian"    => [ 2.3, "words" ],
      "Portuguese" => [ 2.3, "words" ],
      "French"     => [ 2.6, "words" ],
      "German"     => [ 2.2, "words" ],
      "Japanese"   => [ 6.5, "characters" ],
      "Chinese"    => [ 4.2, "characters" ]
    }.freeze
    DEFAULT_BUDGET_RATE = [ 2.4, "words" ].freeze
    MIN_WORD_BUDGET = 3

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      segments = task.segments

      batches = build_batches(segments)
      translations = translate_batches_in_parallel(batches, segments, task.language)

      missing = []
      segments.each_with_index do |seg, i|
        translated = translations[i]
        if translated.to_s.strip.empty?
          missing << i
          seg["translated_text"] = seg["text"]
        else
          seg["translated_text"] = translated
        end
      end
      if missing.any?
        Rails.logger.warn("[TranslateJob] #{missing.size} segments fell back to source text: #{missing.first(10).inspect}")
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
          result = future.value!(BATCH_TIMEOUT_S + 100)
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
        lines << "[#{i}|#{duration}s|#{length_budget(duration, target_lang)}] #{seg["text"]}"
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

    # "max 8 words" (or characters for CJK), computed from the line's duration so
    # the model never has to estimate pace or duration itself.
    def length_budget(duration, target_lang)
      rate, unit = LENGTH_BUDGET_RATES.fetch(target_lang, DEFAULT_BUDGET_RATE)
      budget = [ (duration * rate).floor, MIN_WORD_BUDGET ].max
      "max #{budget} #{unit}"
    end

    def system_prompt(target_lang)
      <<~PROMPT
        You are a professional dubbing translator for film/TV. Translate this transcript to #{target_lang}.

        The input may include [CONTEXT N] lines showing the original-language segments immediately before this batch. Use these only for tone/term/pronoun consistency. DO NOT translate or output anything for [CONTEXT N] lines.

        Translate only the lines formatted as [index|duration|budget].

        Every translation is spoken aloud by a TTS voice that talks at a fixed natural pace, and the audio must finish within the original line's duration. The system measures the generated audio afterwards: a translation that runs over gets mechanically sped up and becomes hard to understand. Running slightly short is completely fine, a small pause is added. When in doubt, ALWAYS pick the shorter phrasing.

        LENGTH RULES (most important):
        1. Each line's budget ("max N words" or "max N characters") is precomputed from its duration and the TTS speaking pace. Stay AT or UNDER the budget.
        2. Fitting the budget beats literal completeness: drop fillers, hedges, and redundancy while keeping the message. Never pad a line that comes out short.
           When you compress, NEVER cut content a learner acts on: negations, numbers, qualifiers like "again", "only", "first", or full technique names (keep "chain of thought prompting", not just "chain of thought").
        3. #{target_lang} may need more words or syllables than English to say the same thing. Compress the phrasing up front, don't translate literally and hope it fits.

        This is the right amount of compression (shown for English to Spanish, do the equivalent in #{target_lang}):
        [3|3.8s|max 8 words] So, what we're going to do now is take a look at zero shot prompting.
        BAD, literal, 15 words: Entonces, lo que vamos a hacer ahora es echar un vistazo al zero shot prompting.
        GOOD, 6 words: Ahora veremos el zero shot prompting.

        STYLE RULES:
        4. Produce natural, spoken-style translations. NOT literal word-by-word.
        5. Prefer contractions and colloquial phrasing over formal/written style.
        6. Preserve the emotional tone and intent, but freely rephrase for natural flow.
        7. NEVER skip a line or leave it empty.
        8. NEVER use em-dashes, en-dashes, or hyphens as parenthetical separators. Use commas instead. The text will be read aloud by TTS.
        9. For technical terms with hyphens (like 'zero-shot'), write them as spoken words (like 'zero shot').

        Return translated lines in same format, one per input line:
        [0|2.5s] Translation here
        [1|3.0s] Next translation
      PROMPT
    end
  end
end
