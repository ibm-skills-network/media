module DubbingPipeline
  class CleanupJob < ApplicationJob
    queue_as :low

    # Files to delete once HLS is built
    # We only need hls/, transcript files and cos_player
    INTERMEDIATE_BASENAMES = %w[
      audio.wav
      source.mp4
      vocals.wav
      background.wav
      transcribe.mp3
      segments_in.json
      mix_segments.json
      mix_tts_files.json
      mix_filtergraph.txt
      tts_track.wav
      ffmpeg_mix.log
      dubbed.mp3
      dubbed.mp4
    ].freeze

    # DB columns to null out since the files they point at are gone
    CLEARED_PATH_COLUMNS = %i[
      audio_path
      source_video_path
      vocals_path
      background_path
      dubbed_audio_path
      dubbed_video_path
    ].freeze

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg["args"].first)
      task&.update!(status: "failed", error_message: exception.message)
    end

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      output_dir = Rails.root.join("tmp", "dubbing", task_id.to_s)

      INTERMEDIATE_BASENAMES.each do |name|
        FileUtils.rm_f(output_dir.join(name))
      end

      Dir.glob(output_dir.join("tts_*.mp3").to_s).each { |p| FileUtils.rm_f(p) }
      Dir.glob(output_dir.join("_speed_*.mp3").to_s).each { |p| FileUtils.rm_f(p) }

      task.update!(CLEARED_PATH_COLUMNS.index_with { nil }.merge(status: "success"))
    end
  end
end
