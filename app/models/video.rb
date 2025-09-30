class Video < ApplicationRecord
  has_many :qualities, class_name: "Videos::Quality", dependent: :destroy

  def create_qualities!(video_params)
    Videos::Quality.qualities.keys.each do |quality|
      qualities.create!(quality: quality)
    end
  end
end
