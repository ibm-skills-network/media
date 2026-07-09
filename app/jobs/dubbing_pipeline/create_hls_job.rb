module DubbingPipeline
  class CreateHlsJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      next unless task
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      hls_master_url = DubbingWorkspace.with("#{task_id}-hls") do |ws|
        dubbed_video_path = ws.fetch(task.dubbed_video, "dubbed.mp4")
        audio_path = ws.fetch(task.audio, "audio.wav")
        dubbed_audio_path = ws.fetch(task.dubbed_audio, "dubbed.m4a")

        # Flat layout in hls_dir so the COS prefix mirrors it 1:1, the player resolves
        # segments, subtitles, and cos_player.json as siblings of master.m3u8
        hls_dir = File.join(ws.dir, "hls")
        FileUtils.mkdir_p(hls_dir)

        duration = DubbingFfprobe.duration_seconds(dubbed_video_path)
        lang_code = task.lang_code
        raise "CreateHlsJob: target language cannot equal source '#{DubbingTask::SOURCE_LANG_CODE}'" if lang_code == DubbingTask::SOURCE_LANG_CODE

        src_code = DubbingTask::SOURCE_LANG_CODE

        vtt_src = File.join(hls_dir, "subs_#{src_code}.webvtt")
        vtt_dub = File.join(hls_dir, "subs_#{lang_code}.webvtt")
        srt_src = File.join(hls_dir, "transcript_#{src_code}.srt")
        srt_dub = File.join(hls_dir, "transcript_#{lang_code}.srt")

        subtitle_segments = task.export_segments
        write_subtitles(subtitle_segments, vtt_src, format: :vtt, use_translated: false)
        write_subtitles(subtitle_segments, vtt_dub, format: :vtt, use_translated: true)
        write_subtitles(subtitle_segments, srt_src, format: :srt, use_translated: false)
        write_subtitles(subtitle_segments, srt_dub, format: :srt, use_translated: true)

        # Video-only stream, fMP4 segments are required for swappable audio tracks
        run_ffmpeg!(
          "-i", dubbed_video_path, "-an", "-c:v", "copy",
          "-f", "hls", "-hls_time", "6",
          "-hls_segment_type", "fmp4",
          "-hls_segment_filename", File.join(hls_dir, "seg_v_%03d.mp4"),
          "-hls_fmp4_init_filename", "init_v.mp4",
          "-hls_playlist_type", "vod",
          File.join(hls_dir, "playlist_v.m3u8"),
          error: "HLS video segmenting failed"
        )

        # English audio track
        run_ffmpeg!(
          "-i", audio_path, "-acodec", "aac", "-b:a", "128k", "-ac", "2",
          "-f", "hls", "-hls_time", "6",
          "-hls_segment_type", "fmp4",
          "-hls_segment_filename", File.join(hls_dir, "seg_a-eng_%03d.mp4"),
          "-hls_fmp4_init_filename", "init_a-eng.mp4",
          "-hls_playlist_type", "vod",
          File.join(hls_dir, "playlist_a-eng.m3u8"),
          error: "HLS english audio failed"
        )

        # Dubbed audio, same encoding as English so the player switches cleanly
        run_ffmpeg!(
          "-i", dubbed_audio_path, "-acodec", "aac", "-b:a", "128k", "-ac", "2",
          "-f", "hls", "-hls_time", "6",
          "-hls_segment_type", "fmp4",
          "-hls_segment_filename", File.join(hls_dir, "seg_a-dub_%03d.mp4"),
          "-hls_fmp4_init_filename", "init_a-dub.mp4",
          "-hls_playlist_type", "vod",
          File.join(hls_dir, "playlist_a-dub.m3u8"),
          error: "HLS dubbed audio failed"
        )

        # One subtitle playlist per language, each wrapping its .webvtt as a single segment
        [ src_code, lang_code ].uniq.each do |lang|
          File.write(File.join(hls_dir, "playlist_s-#{lang}.m3u8"), <<~M3U8)
            #EXTM3U
            #EXT-X-TARGETDURATION:#{duration.to_i + 1}
            #EXT-X-VERSION:3
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:#{format('%.3f', duration)},
            subs_#{lang}.webvtt
            #EXT-X-ENDLIST
          M3U8
        end

        # VTT chapters for the HLS player, JSON chapters for the COS Player UI
        write_chapters_vtt(task.chapters, File.join(hls_dir, "chapters_#{src_code}.vtt"), duration, key: "title")
        write_chapters_vtt(task.chapters, File.join(hls_dir, "chapters_#{lang_code}.vtt"), duration, key: "title_dubbed")
        File.write(File.join(hls_dir, "chapters.json"), JSON.pretty_generate(task.chapters))

        write_master_playlist(File.join(hls_dir, "master.m3u8"), task.language, lang_code, src_code)
        write_cos_player_json(task, hls_dir, duration, lang_code)

        DubbingHlsUploader.upload_dir(hls_dir, task)
      end

      task.update!(hls_path: hls_master_url)
      DubbingPipeline::CleanupJob.perform_later(task_id)
    end

    private

    def run_ffmpeg!(*args, error:)
      _stdout, stderr, status = Open3.capture3("ffmpeg", "-y", *args)
      raise "#{error}: #{stderr}" unless status.success?
    end

    # HH:MM:SS<sep>mmm, VTT uses ".", SRT uses ","
    def fmt_timestamp(seconds, ms_sep:)
      h = (seconds / 3600).to_i
      m = ((seconds % 3600) / 60).to_i
      s = (seconds % 60).to_i
      ms = ((seconds % 1) * 1000).to_i
      format("%02d:%02d:%02d#{ms_sep}%03d", h, m, s, ms)
    end

    def write_subtitles(segments, path, format:, use_translated:)
      ms_sep = format == :vtt ? "." : ","
      File.open(path, "w") do |f|
        f.write("WEBVTT\n\n") if format == :vtt
        segments.each_with_index do |seg, i|
          text = use_translated ? seg["translated_text"] : seg["text"]
          line = format == :vtt ? "<v #{seg["speaker"]}>#{text}" : text
          f.write("#{i + 1}\n")
          f.write("#{fmt_timestamp(seg["start"], ms_sep: ms_sep)} --> #{fmt_timestamp(seg["end"], ms_sep: ms_sep)}\n")
          f.write("#{line}\n\n")
        end
      end
    end

    def write_chapters_vtt(chapters, path, duration, key:)
      File.open(path, "w") do |f|
        f.write("WEBVTT\n\n")
        chapters.each_with_index do |ch, i|
          # Each chapter ends where the next one starts, the last runs to video end
          end_time = chapters[i + 1] ? chapters[i + 1]["start"] : duration
          title = ch[key] || ch["title"]
          f.write("Chapter #{i + 1}\n")
          f.write("#{fmt_timestamp(ch["start"], ms_sep: ".")} --> #{fmt_timestamp(end_time, ms_sep: ".")}\n")
          f.write("#{title}\n\n")
        end
      end
    end

    def write_master_playlist(path, language, lang_code, src_code)
      src_name = DubbingTask::SOURCE_LANG_NAME
      # DEFAULT=YES is the track the player loads on startup, AUTOSELECT=YES lets the user pick it
      File.write(path, <<~M3U8)
        #EXTM3U

        #EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-dub.m3u8",GROUP-ID="audio",LANGUAGE="#{lang_code}",NAME="#{language}",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-eng.m3u8",GROUP-ID="audio",LANGUAGE="#{src_code}",NAME="#{src_name}",AUTOSELECT=YES

        #EXT-X-MEDIA:TYPE=SUBTITLES,URI="playlist_s-#{src_code}.m3u8",GROUP-ID="subs",LANGUAGE="#{src_code}",NAME="#{src_name}",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=SUBTITLES,URI="playlist_s-#{lang_code}.m3u8",GROUP-ID="subs",LANGUAGE="#{lang_code}",NAME="#{language}",AUTOSELECT=YES

        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="audio",SUBTITLES="subs"
        playlist_v.m3u8
      M3U8
    end

    def write_cos_player_json(task, output_dir, duration, lang_code)
      src_code = DubbingTask::SOURCE_LANG_CODE
      src_name = DubbingTask::SOURCE_LANG_NAME

      chapter_list = task.chapters.each_with_index.map do |ch, i|
        end_time = task.chapters[i + 1] ? task.chapters[i + 1]["start"] : duration
        # Slugify the title for the id, "Intro to AI!" becomes "intro_to_ai"
        ch_id = ch["title"].to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/(^_|_$)/, "")
        {
          id: ch_id,
          start: ch["start"],
          end: end_time.round(1),
          title: ch["title"],
          title_dubbed: ch["title_dubbed"]
        }
      end

      cos_config = {
        version: 2,
        video: {
          title: "",
          chapters: chapter_list,
          # All assets share the prefix with cos_player.json, so the player resolves them
          # as siblings of master.m3u8
          videos: [ { url: "master.m3u8", quality: "original", downloadable: true, hd: true } ],
          subtitles: [
            { url: "transcript_#{src_code}.srt", label: src_name, language: src_code.upcase, format: "srt" },
            { url: "transcript_#{lang_code}.srt", label: task.language, language: lang_code.upcase, format: "srt" }
          ]
        }
      }

      File.write(File.join(output_dir, "cos_player.json"), JSON.pretty_generate(cos_config))
    end
  end
end
