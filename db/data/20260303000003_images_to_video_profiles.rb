# frozen_string_literal: true

class ImagesToVideoProfiles < ActiveRecord::Migration[8.1]
  def up
    profiles = [
      {
        codec: "libvpx-vp9",
        audio_codec: "libopus",
        container: "webm",
        extra_video_options: [ "-cpu-used", "8", "-deadline", "realtime", "-row-mt", "1" ],
        gpu: false
      },
      {
        codec: "av1_nvenc",
        audio_codec: "aac",
        container: "mp4",
        extra_video_options: [],
        gpu: true
      }
    ]

    profiles.each do |attributes|
      Videos::ImagesToVideoProfile.find_or_initialize_by(codec: attributes[:codec]).update!(attributes)
    end
  end
end
