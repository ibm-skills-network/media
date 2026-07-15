module DubbingPipeline
  class IdentifyChaptersJob < BaseJob
    def perform(task_id)
      task = DubbingTask.find(task_id)
      return if task.failed? || task.success?

      transcript = task.segments.map do |seg|
        "[#{seg["start"].round(1)}s - #{seg["end"].round(1)}s] #{seg["text"]}"
      end.join("\n")

      content = OpenaiChat.complete(
        label: "GPT chapters",
        response_format: { type: "json_object" },
        timeout: 120,
        messages: [
          {
            role: "system",
            content: <<~PROMPT
                You are a video editor segmenting a lecture or talk into chapters for a player's chapter menu.

                Aim for roughly one chapter every 2 to 4 minutes, with a minimum of 2 and a maximum of 12 chapters. Return an empty chapters array if the video is under 90 seconds.

                Each chapter should mark a real topical shift — a new concept, a new example, a new section of the argument. Do not insert chapters just to hit a count.

                Return a JSON object: { "chapters": [{ "start": <seconds float>, "title": "<English, max 60 chars>", "title_dubbed": "<#{task.language} translation, max 60 chars>" }] }
            PROMPT
          },
          {
            role: "user",
            content: transcript
          }
        ]
      )

      parsed = JSON.parse(content)
      # The model controls this JSON, so coerce/sort before any timestamp arithmetic on it
      chapters = (parsed["chapters"] || []).map do |ch|
        ch.merge(
          "start" => [ ch["start"].to_f, 0.0 ].max,
          "title" => ch["title"].to_s[0, 60],
          "title_dubbed" => ch["title_dubbed"].to_s[0, 60]
        )
      end.sort_by { |ch| ch["start"] }
      task.update!(chapters: chapters)
      DubbingPipeline::TranslateJob.perform_later(task_id)
    end
  end
end
