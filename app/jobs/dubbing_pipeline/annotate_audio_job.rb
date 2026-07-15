module DubbingPipeline
  class AnnotateAudioJob < BaseJob
    queue_as :gpu

    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      annotated = DubbingWorkspace.with("#{task_id}-annotate") do |ws|
        vocals_path = ws.fetch(task.vocals, "vocals.wav")
        segments_in_path = ws.path("segments_in.json")
        File.write(segments_in_path, task.segments.to_json)

        stdout, stderr, status = Open3.capture3(
          "python3", Rails.root.join("script/dubbing/annotate_audio.py").to_s,
          vocals_path,
          "--segments-file", segments_in_path,
          "--output-dir", ws.dir
        )
        raise "Audio annotation failed: #{stderr}" unless status.success?

        JSON.parse(stdout)
      end

      task.update!(segments: annotated)
      DubbingPipeline::IdentifyChaptersJob.perform_later(task_id)
    end
  end
end
