module DubbingPipeline
  class TranscribeJob < BaseJob
    # The transcription request is streamed (SSE) rather than waited on as one
    # big response: non-streamed requests sit idle while OpenAI processes, and
    # past ~5 minutes of processing the idle connection gets dropped and the
    # response never arrives (observed: 60s of audio -> 22s, 7min -> 275s,
    # 10min -> hangs until the read timeout). With streaming, segment events
    # flow as they're transcribed, so the connection never looks idle and no
    # timeout has to cover the whole file -- only the gap between events.
    EVENT_GAP_TIMEOUT = 120

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      api_segments = DubbingWorkspace.with("#{task_id}-transcribe") do |ws|
        audio_path = ws.fetch(task.audio, "audio.wav")
        ogg_path = ws.path("transcribe.ogg")

        # Opus instead of mp3, the worker ffmpeg is built without libmp3lame
        _stdout, stderr, status = Open3.capture3(
          "ffmpeg", "-y",
          "-i", audio_path,
          "-ar", "16000",
          "-ac", "1",
          "-c:a", "libopus",
          "-b:a", "32k",
          ogg_path
        )
        raise "ffmpeg compression failed: #{stderr}" unless status.success?

        stream_transcription(ogg_path)
      end

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

    # Collects transcript.text.segment SSE events into the same segment hashes
    # the non-streamed diarized_json response would return
    def stream_transcription(ogg_path)
      segments = []
      buffer = +""

      conn = Faraday.new do |f|
        f.request :multipart
        f.options.timeout = EVENT_GAP_TIMEOUT
        f.options.open_timeout = 10
      end

      response = conn.post("https://api.openai.com/v1/audio/transcriptions") do |req|
        req.headers["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
        req.body = {
          file: Faraday::Multipart::FilePart.new(ogg_path, "audio/ogg"),
          model: "gpt-4o-transcribe-diarize",
          response_format: "diarized_json",
          chunking_strategy: "auto",
          stream: "true"
        }
        req.options.on_data = proc do |chunk, _received_bytes, env|
          next unless env.status == 200

          buffer << chunk
          segments.concat(drain_segment_events(buffer))
        end
      end
      raise "Transcription failed: HTTP #{response.status}" unless response.success?

      segments
    end

    # Consumes complete SSE events from the front of the buffer, leaving any
    # partial trailing event in place for the next chunk of bytes
    def drain_segment_events(buffer)
      events = []
      while (boundary = buffer.index("\n\n"))
        block = buffer.slice!(0, boundary + 2)
        block.each_line do |line|
          payload = line.delete_prefix("data:").strip
          next if payload == line.strip # not a data line
          next if payload.empty? || payload == "[DONE]"

          event = JSON.parse(payload)
          events << event if event["type"] == "transcript.text.segment"
        end
      end
      events
    end

    def merge_into_sentences(segments)
      return segments if segments.empty?

      marked_text = segments.each_with_index.map { |s, i| "[#{i}:#{format('%.2f', s["start"])}] #{s["text"]}" }.join(" ")

      content = OpenaiChat.complete(
        label: "GPT sentence-merge",
        response_format: { type: "json_object" },
        timeout: 600,
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
      )

      parsed = JSON.parse(content)
      data = parsed["sentences"]
      unless data.is_a?(Array)
        Rails.logger.warn("[TranscribeJob] GPT returned no sentences array for merge: #{parsed.inspect[0, 200]}")
        return segments
      end
      # Pull the original fragment index out of GPT's [idx:time] markers.
      marker_pattern = /\[(\d+):([\d.]+)\]/

      start_indices = data.map do |item|
        m = item["start_marker"].to_s.match(marker_pattern)
        m ? m[1].to_i.clamp(0, segments.length - 1) : nil
      end

      new_segments = data.each_with_index.filter_map do |item, i|
        text = item["text"].to_s.strip
        next if text.empty?

        # A merged sentence spans from its start marker up to (but not including) the next one.
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
