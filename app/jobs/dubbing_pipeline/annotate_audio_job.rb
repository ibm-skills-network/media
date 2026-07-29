module DubbingPipeline
  class AnnotateAudioJob < ApplicationJob
    queue_as :low

    WAIT_FOR_VOCALS_S = 15
    MAX_VOCALS_WAITS = 80

    sidekiq_retries_exhausted do |msg, exception|
      task = DubbingTask.find_by(id: msg.dig("args", 0, "arguments", 0))
      next if task.nil? || task.terminal?
      task.update!(status: "failed", error_message: exception.message)
      task.purge_pipeline_artifacts!(include_hls: true)
    end

    # Joins the extract fan-out; re-enqueues rather than raising so waiting on
    # Demucs doesn't spend the retry budget kept for real failures.
    def perform(task_id, vocals_waits = 0)
      task = DubbingTask.find(task_id)
      return if task.terminal?

      unless task.vocals.attached?
        if vocals_waits >= MAX_VOCALS_WAITS
          raise "Vocals never became available after " \
                "#{MAX_VOCALS_WAITS * WAIT_FOR_VOCALS_S}s; SeparateAudioJob likely failed"
        end

        self.class.set(wait: WAIT_FOR_VOCALS_S).perform_later(task_id, vocals_waits + 1)
        return
      end

      annotated = DubbingWorkspace.with("#{task_id}-annotate") do |ws|
        vocals_path = ws.fetch(task.vocals, "vocals.wav")
        segments_in_path = ws.path("segments_in.json")
        File.write(segments_in_path, task.segments.to_json)

        stdout, stderr, status = Open3.capture3(
          "python3", Rails.root.join("script/dubbing/annotate_audio.py").to_s,
          vocals_path,
          "--segments-file", segments_in_path
        )
        raise "Audio annotation failed: #{stderr}" unless status.success?

        JSON.parse(stdout)
      end

      task.update!(segments: annotated)
      DubbingPipeline::IdentifyChaptersJob.perform_later(task_id)
    end
  end
end
