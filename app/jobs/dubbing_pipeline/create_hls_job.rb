module DubbingPipeline
  class CreateHlsJob < ApplicationJob
    queue_as :default

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s).to_s
      hls_dir = File.join(output_dir, "hls")
      FileUtils.mkdir_p(hls_dir)

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y", "-i", task.dubbed_video_path, "-an", "-c:v", "copy",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", File.join(hls_dir, "seg_v_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_v.mp4",
        "-hls_playlist_type", "vod",
        File.join(hls_dir, "playlist_v.m3u8")
      )
      raise "HLS video segmenting failed: #{stderr}" unless status.success?

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y", "-i", task.video_url, "-vn", "-acodec", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", File.join(hls_dir, "seg_a-eng_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_a-eng.mp4",
        "-hls_playlist_type", "vod",
        File.join(hls_dir, "playlist_a-eng.m3u8")
      )
      raise "HLS english audio failed: #{stderr}" unless status.success?

      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-y", "-i", task.dubbed_audio_path, "-acodec", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", File.join(hls_dir, "seg_a-dub_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_a-dub.mp4",
        "-hls_playlist_type", "vod",
        File.join(hls_dir, "playlist_a-dub.m3u8")
      )
      raise "HLS dubbed audio failed: #{stderr}" unless status.success?

      lang_code = task.language.downcase[0..1]
      File.write(File.join(hls_dir, "master.m3u8"), <<~M3U8)
        #EXTM3U

        #EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-eng.m3u8",GROUP-ID="audio",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-dub.m3u8",GROUP-ID="audio",LANGUAGE="#{lang_code}",NAME="#{task.language}",AUTOSELECT=YES

        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="audio"
        playlist_v.m3u8
      M3U8

      task.update!(status: "success")
    end
  end
end
