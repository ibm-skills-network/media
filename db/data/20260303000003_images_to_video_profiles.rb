# frozen_string_literal: true

class ImagesToVideoProfiles < ActiveRecord::Migration[8.1]
  def up
    profiles = {
      "vp9" => {
        codec: "libvpx-vp9",
        audio_codec: "libopus",
        container: "webm",
        extra_video_options: [ "-cpu-used", "8", "-deadline", "realtime", "-row-mt", "1" ],
        gpu: false
      },
      "av1_nvenc" => {
        codec: "av1_nvenc",
        audio_codec: "aac",
        container: "mp4",
        extra_video_options: [],
        gpu: true
      }
    }

    profiles.each do |label, attributes|
      profile = Videos::ImagesToVideoProfile.find_or_initialize_by(label: label)
      profile.update!(
        codec: attributes[:codec],
        audio_codec: attributes[:audio_codec],
        container: attributes[:container],
        extra_video_options: attributes[:extra_video_options],
        gpu: attributes[:gpu]
      )
    end
  end
end
