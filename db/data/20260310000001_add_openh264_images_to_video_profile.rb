# frozen_string_literal: true

class AddOpenh264ImagesToVideoProfile < ActiveRecord::Migration[8.1]
  def up
    Videos::ImagesToVideoProfile.find_or_initialize_by(codec: "libopenh264").update!(
      audio_codec: "aac",
      container: "mp4",
      extra_video_options: [ "-b:v", "2M" ],
      gpu: false
    )
  end
end
