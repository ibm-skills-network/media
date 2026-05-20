module DubbingPipeline
  class TranslateJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 15
    CONTEXT_OVERLAP = 2
    MAX_CONCURRENCY = 5
    BATCH_TIMEOUT_S = 600
    MAX_BATCH_RETRIES = 3

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
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
        failures = []
        futures.each_with_index do |future, idx|
          result = future.value!(BATCH_TIMEOUT_S + 100)
          translations.merge!(result) if result.is_a?(Hash)
        rescue => e
          Rails.logger.error("[TranslateJob] batch #{idx} failed: #{e.class}: #{e.message}")
          failures << { idx: idx, error: e.message }
        end

        if failures.any?
          Rails.logger.error("[TranslateJob] #{failures.size}/#{batches.size} batches failed")
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
        word_count = seg["text"].split.length
        lines << "[#{i}|#{duration}s|#{word_count}w] #{seg["text"]}"
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

      raise "GPT translate failed: #{response.status} #{response.body}" unless response.success?

      result = JSON.parse(response.body)["choices"][0]["message"]["content"].to_s

      parsed = {}
      result.split("\n").each do |line|
        match = line.strip.match(/\[(\d+)\|[\d.]+s(?:\|\d+w)?\]\s*(.+)/)
        next unless match
        idx = match[1].to_i
        parsed[idx] = match[2].strip if batch[:translate_range].include?(idx)
      end
      parsed
    end

    def system_prompt(target_lang)
      <<~PROMPT
        You are a professional dubbing translator for film/TV. Translate this transcript to #{target_lang}.

        The input may include [CONTEXT N] lines showing the original-language segments immediately before this batch. Use these only for tone/term/pronoun consistency. DO NOT translate or output anything for [CONTEXT N] lines.

        Translate only the lines formatted as [index|duration|word_count].

        RULES:
        1. Produce natural, spoken-style translations. NOT literal word-by-word.
        2. Match the syllable count of the original as closely as possible for lip sync.
        3. Each translation MUST be speakable within the given duration at ~4 syllables/second.
        4. Prefer contractions and colloquial phrasing over formal/written style.
        5. Preserve the emotional tone and intent, but freely rephrase for natural flow.
        6. If a line is too long for the duration, shorten creatively while keeping meaning.
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
