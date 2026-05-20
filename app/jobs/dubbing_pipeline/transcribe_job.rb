module DubbingPipeline
  class TranscribeJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)

      mp3_path = Rails.root.join("tmp", "dubbing", task_id.to_s, "transcribe.mp3").to_s

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y",
        "-i", task.audio_path,
        "-ar", "16000",
        "-ac", "1",
        "-b:a", "64k",
        mp3_path
      )
      raise "ffmpeg compression failed: #{stderr}" unless status.success?

      conn = Faraday.new do |f|
        f.request :multipart
        f.options.timeout = 300
        f.options.open_timeout = 10
      end

      file = Faraday::Multipart::FilePart.new(mp3_path, "audio/mpeg")
      response = conn.post("https://api.openai.com/v1/audio/transcriptions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
        req.body = {
          file: file,
          model: "gpt-4o-transcribe-diarize",
          response_format: "diarized_json",
          chunking_strategy: "auto"
        }
      end
      raise "Transcription failed: #{response.status} #{response.body}" unless response.success?

      api_segments = JSON.parse(response.body)["segments"] || []

      speaker_id_map = {}
      raw_segments = api_segments.filter_map do |seg|
        text = seg["text"].to_s.strip
        next if text.empty?

        api_speaker = seg["speaker"].to_s
        speaker_id_map[api_speaker] ||= "SPEAKER_#{speaker_id_map.size}"

        {
          "start" => seg["start"].to_f,
          "end" => seg["end"].to_f,
          "text" => text,
          "speaker" => speaker_id_map[api_speaker]
        }
      end

      Rails.logger.info("[TranscribeJob] Got #{raw_segments.size} segments, #{speaker_id_map.size} speaker(s)")

      segments = merge_into_sentences(raw_segments)
      task.update!(segments: segments)

      DubbingPipeline::AnnotateAudioJob.perform_later(task_id)
    end

    private

    def merge_into_sentences(segments)
      return segments if segments.empty?

      marked_text = segments.each_with_index.map { |s, i| "[#{i}:#{format('%.2f', s["start"])}] #{s["text"]}" }.join(" ")

      conn = Faraday.new do |f|
        f.options.timeout = 600
        f.options.open_timeout = 10
      end
      response = conn.post("https://api.openai.com/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: "gpt-5-mini",
          response_format: { type: "json_object" },
          messages: [
            {
              role: "system",
              content: <<~PROMPT
                You are a transcript editor preparing text for dubbing translation.

                The input is auto-transcribed speech chopped into fragments by a speech recognizer. Many fragments are MID-SENTENCE and must be merged before translation.

                Your job: reconstruct the COMPLETE, NATURAL SENTENCES the speaker actually said.

                Rules:
                - AGGRESSIVELY merge fragments. If a fragment doesn't end with . ? or ! it is NOT a complete sentence — merge it with the next fragment(s)
                - Every output MUST be a grammatically complete sentence that can stand alone
                - Use the timestamp marker [X:Y.YY] from the FIRST fragment of each merged sentence
                - Don't split at abbreviations like 'Dr.', 'Mr.', 'U.S.', 'e.g.'
                - Add proper end punctuation (. ? !) to every sentence
                - NEVER use em-dashes or en-dashes. Use commas or periods instead. The text will be spoken aloud by TTS.
                - For hyphenated technical terms (zero-shot, chain-of-thought), remove the hyphens
                - Return a JSON object: {"sentences": [{"start_marker": "[0:1.23]", "text": "Complete sentence."}]}
              PROMPT
            },
            { role: "user", content: marked_text }
          ]
        }.to_json
      end

      raise "GPT sentence-merge failed: #{response.status} #{response.body}" unless response.success?

      parsed = JSON.parse(JSON.parse(response.body)["choices"][0]["message"]["content"])
      data = parsed["sentences"]
      unless data.is_a?(Array)
        Rails.logger.warn("[TranscribeJob] GPT returned no sentences array for merge: #{parsed.inspect[0, 200]}")
        return segments
      end
      marker_pattern = /\[(\d+):([\d.]+)\]/

      start_indices = data.map do |item|
        m = item["start_marker"].to_s.match(marker_pattern)
        m ? m[1].to_i.clamp(0, segments.length - 1) : nil
      end

      new_segments = data.each_with_index.filter_map do |item, i|
        text = item["text"].to_s.strip
        next if text.empty?

        src_start_idx = start_indices[i] || 0
        next_src_start_idx = start_indices[i + 1] || segments.length
        last_src_idx = [ next_src_start_idx - 1, src_start_idx ].max
        last_src_idx = [ last_src_idx, segments.length - 1 ].min

        start = segments[src_start_idx]["start"]
        end_time = segments[last_src_idx]["end"]
        speaker = segments[src_start_idx]["speaker"]

        merged = { "start" => start, "end" => [ end_time, start + 0.5 ].max, "text" => text }
        merged["speaker"] = speaker if speaker
        merged
      end

      new_segments.empty? ? segments : new_segments
    end
  end
end
