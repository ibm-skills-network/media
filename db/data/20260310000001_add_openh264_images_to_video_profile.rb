# frozen_string_literal: true

class AddOpenh264ImagesToVideoProfile < ActiveRecord::Migration[8.1]
  def up
    profile = Videos::ImagesToVideoProfile.find_or_initialize_by(label: "openh264")
    profile.update!(
      codec: "libopenh264",
      audio_codec: "aac",
      container: "mp4",
      extra_video_options: [ "-b:v", "2M" ],
      gpu: false
    )
  end
end
