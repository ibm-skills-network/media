# frozen_string_literal: true

class TranscodingProfiles < ActiveRecord::Migration[8.0]
  def up
    profiles = {
      "1080p" => {
        codec: "av1_nvenc",
        width: 1920,
        height: 1080,
        bitrate: "2900k",
        bitrate_int: 2_900_000
      },
      "720p" => {
        codec: "av1_nvenc",
        width: 1280,
        height: 720,
        bitrate: "1800k",
        bitrate_int: 1_800_000
      },
      "480p" => {
        codec: "av1_nvenc",
        width: 854,
        height: 480,
        bitrate: "1000k",
        bitrate_int: 1_000_000
      }
    }

    profiles.each do |label, attributes|
      Videos::Quality::TranscodingProfile.create!(
        label: label,
        codec: attributes[:codec],
        width: attributes[:width],
        height: attributes[:height],
        bitrate_string: attributes[:bitrate],
        bitrate_int: attributes[:bitrate_int]
      )
    end
  end

  def down
  end
end
