class Video < ApplicationRecord
  has_many :qualities, class_name: "Videos::Quality", dependent: :destroy

  def create_qualities!(video_params)
    Videos::Quality.qualities.keys.each do |quality|
      q = qualities.create!(quality: quality)
      q.encode_video_later
    end
  end
end
