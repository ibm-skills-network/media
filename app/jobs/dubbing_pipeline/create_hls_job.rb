module DubbingPipeline
  class CreateHlsJob < ApplicationJob
    queue_as :low

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s
      hls_dir = File.join(output_dir, "hls")
      FileUtils.mkdir_p(hls_dir)

      duration = probe_duration(task.dubbed_video_path)
      lang_code = task.lang_code
      raise "CreateHlsJob: target language cannot equal source '#{DubbingTask::SOURCE_LANG_CODE}'" if lang_code == DubbingTask::SOURCE_LANG_CODE

      # VTT is consumed by the HLS player via the subtitle playlists, so it lives in hls_dir
      # SRT is consumed by the COS Player config (cos_player.json), so it lives in output_dir
      vtt_en  = File.join(hls_dir, "subs_en.webvtt")
      vtt_dub = File.join(hls_dir, "subs_#{lang_code}.webvtt")
      srt_en  = File.join(output_dir, "transcript_en.srt")
      srt_dub = File.join(output_dir, "transcript_#{lang_code}.srt")

      subtitle_segments = task.export_segments
      write_subtitles(subtitle_segments, vtt_en, format: :vtt, use_translated: false)
      write_subtitles(subtitle_segments, vtt_dub, format: :vtt, use_translated: true)
      write_subtitles(subtitle_segments, srt_en, format: :srt, use_translated: false)
      write_subtitles(subtitle_segments, srt_dub, format: :srt, use_translated: true)

      # Video-only HLS stream, fMP4 segments are needed so audio tracks can be swapped
      run_ffmpeg!(
        "-i", task.dubbed_video_path, "-an", "-c:v", "copy",
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
        "-i", task.audio_path, "-acodec", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", File.join(hls_dir, "seg_a-eng_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_a-eng.mp4",
        "-hls_playlist_type", "vod",
        File.join(hls_dir, "playlist_a-eng.m3u8"),
        error: "HLS english audio failed"
      )

      # Dubbed audio track, same encoding as English so the player can switch cleanly
      run_ffmpeg!(
        "-i", task.dubbed_audio_path, "-acodec", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", File.join(hls_dir, "seg_a-dub_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_a-dub.mp4",
        "-hls_playlist_type", "vod",
        File.join(hls_dir, "playlist_a-dub.m3u8"),
        error: "HLS dubbed audio failed"
      )

      # One subtitle playlist per language, wrapping the .webvtt as a single HLS segment
      [ "en", lang_code ].uniq.each do |lang|
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
      write_chapters_vtt(task.chapters, File.join(hls_dir, "chapters_en.vtt"), duration, key: "title")
      write_chapters_vtt(task.chapters, File.join(hls_dir, "chapters_#{lang_code}.vtt"), duration, key: "title_dubbed")
      File.write(File.join(output_dir, "chapters.json"), JSON.pretty_generate(task.chapters))

      # Master playlist, creates file which player loads to start the stream
      write_master_playlist(File.join(hls_dir, "master.m3u8"), task.language, lang_code)

      # COS Player config, points at the HLS stream and lists the SRT subtitle files
      write_cos_player_json(task, output_dir, duration, lang_code)

      task.update!(hls_path: File.join(hls_dir, "master.m3u8"), status: "success")
    end

    private

    def run_ffmpeg!(*args, error:)
      _stdout, stderr, status = Open3.capture3("ffmpeg", "-y", *args)
      raise "#{error}: #{stderr}" unless status.success?
    end

    def probe_duration(path)
      out, _err, status = Open3.capture3(
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        path
      )
      raise "ffprobe failed for #{path}" unless status.success?
      out.strip.to_f
    end

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
          end_time = chapters[i + 1] ? chapters[i + 1]["start"] : duration
          title = ch[key] || ch["title"]
          f.write("Chapter #{i + 1}\n")
          f.write("#{fmt_timestamp(ch["start"], ms_sep: ".")} --> #{fmt_timestamp(end_time, ms_sep: ".")}\n")
          f.write("#{title}\n\n")
        end
      end
    end

    def write_master_playlist(path, language, lang_code)
      File.write(path, <<~M3U8)
        #EXTM3U

        #EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-eng.m3u8",GROUP-ID="audio",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-dub.m3u8",GROUP-ID="audio",LANGUAGE="#{lang_code}",NAME="#{language}",AUTOSELECT=YES

        #EXT-X-MEDIA:TYPE=SUBTITLES,URI="playlist_s-en.m3u8",GROUP-ID="subs",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=SUBTITLES,URI="playlist_s-#{lang_code}.m3u8",GROUP-ID="subs",LANGUAGE="#{lang_code}",NAME="#{language}",AUTOSELECT=YES

        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="audio",SUBTITLES="subs"
        playlist_v.m3u8
      M3U8
    end

    def write_cos_player_json(task, output_dir, duration, lang_code)
      chapter_list = task.chapters.each_with_index.map do |ch, i|
        end_time = task.chapters[i + 1] ? task.chapters[i + 1]["start"] : duration
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
          videos: [ { url: "/hls/master.m3u8", quality: "original", downloadable: true, hd: true } ],
          subtitles: [
            { url: "/transcript_en.srt", label: "English", language: "EN", format: "srt" },
            { url: "/transcript_#{lang_code}.srt", label: task.language, language: lang_code.upcase, format: "srt" }
          ]
        }
      }

      File.write(File.join(output_dir, "cos_player.json"), JSON.pretty_generate(cos_config))
    end
  end
end
