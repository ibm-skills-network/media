module DubbingPipeline
  class TranscribeJob < ApplicationJob
    queue_as :low

    # The transcription request is streamed (SSE) rather than waited on as one
    # big response: non-streamed requests sit idle while OpenAI processes, and
    # past ~5 minutes of processing the idle connection gets dropped and the
    # response never arrives (observed: 60s of audio -> 22s, 7min -> 275s,
    # 10min -> hangs until the read timeout). With streaming, segment events
    # flow as they're transcribed, so the connection never looks idle.
    #
    # Wire format (captured from the live API 2026-07-16): CRLF-delimited SSE,
    # `transcript.text.segment` events with speaker/start/end/text, then one
    # `transcript.text.done` event and a `data: [DONE]` sentinel.
    #
    # READ_GAP_TIMEOUT only bounds silence between socket reads, and keep-alive
    # bytes reset it -- so a wall-clock deadline scaled to the audio length
    # backstops streams that trickle bytes without ever finishing.
    READ_GAP_TIMEOUT = 120
    OVERALL_TIMEOUT_BASE = 300
    ERROR_BODY_LIMIT = 2_000

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

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

      # An empty transcript would sail through translation and TTS into a
      # silent dub; fail the task loudly instead.
      raise "Transcription returned no speech segments" if raw_segments.empty?

      Rails.logger.info("[TranscribeJob] Got #{raw_segments.size} segments, #{speaker_id_map.size} speaker(s)")

      segments = merge_into_sentences(raw_segments)
      task.update!(segments: segments)

      DubbingPipeline::AnnotateAudioJob.perform_later(task_id)
    end

    private

    # Collects transcript.text.segment SSE events into the same segment hashes
    # the non-streamed diarized_json response would return
    def stream_transcription(ogg_path)
      audio_s = DubbingFfprobe.duration_seconds(ogg_path)
      overall_timeout = OVERALL_TIMEOUT_BASE + 2 * audio_s
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + overall_timeout

      segments = []
      event_counts = Hash.new(0)
      done = false
      error_body = +""
      sse = SseBuffer.new

      conn = Faraday.new do |f|
        f.request :multipart
        f.options.timeout = READ_GAP_TIMEOUT
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
          # Some adapters don't expose the status mid-stream; treat unknown as OK
          # and let the final response check catch failures.
          if env.status && env.status != 200
            error_body << chunk if error_body.bytesize < ERROR_BODY_LIMIT
            next
          end

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise "Transcription exceeded #{overall_timeout.round}s deadline for #{audio_s.round}s of audio"
          end

          sse.feed(chunk).each do |payload|
            if payload == "[DONE]"
              done = true
              next
            end

            event = parse_stream_event(payload)
            event_counts[event["type"]] += 1
            done = true if event["type"] == "transcript.text.done"
            segments << event if event["type"] == "transcript.text.segment"
          end
        end
      end

      unless response.success?
        raise "Transcription failed: HTTP #{response.status}: #{error_body.byteslice(0, 500)}"
      end
      unless done
        raise "Transcription stream ended without a terminal event, likely truncated " \
              "(events so far: #{event_counts.inspect})"
      end

      Rails.logger.info("[TranscribeJob] stream complete: #{event_counts.inspect}")
      segments
    end

    def parse_stream_event(payload)
      JSON.parse(payload)
    rescue JSON::ParserError
      raise "Transcription stream sent an unparseable event: #{payload.byteslice(0, 200)}"
    end

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

      raise "GPT sentence-merge failed: HTTP #{response.status}" unless response.success?

      parsed = JSON.parse(JSON.parse(response.body)["choices"][0]["message"]["content"])
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
