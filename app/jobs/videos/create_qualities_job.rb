module Videos
  class CreateQualitiesJob < ApplicationJob
    queue_as :critical

    def perform(video_id)
      video = Video.find(video_id)
      video.create_1080p_quality!
    end
  end
end
