module Videos
  class TranscodingTask < ApplicationRecord
    self.table_name = "videos_qualities_transcoding_processes"

    has_one_attached :video_file
    belongs_to :video
    belongs_to :transcoding_profile, class_name: "Videos::TranscodingProfile"

    delegate :label, to: :transcoding_profile

    enum :status, { pending: 0, processing: 1, success: 2, failed: 3, unavailable: 4 }, default: :pending


    def self.create_transcoding_tasks!(video, labels)
      max_quality_value = ::Videos::TranscodingProfile.labels[video.max_quality_label]
      transcoding_profiles = ::Videos::TranscodingProfile.where(label: labels)
      transcoding_profiles.each do |transcoding_profile|
        if max_quality_value < ::Videos::TranscodingProfile.labels[transcoding_profile.label]
          video.transcoding_tasks.create!(transcoding_profile: transcoding_profile, status: :unavailable)
        else
          video.transcoding_tasks.create!(transcoding_profile: transcoding_profile)
        end
      end
    end
  end
end
