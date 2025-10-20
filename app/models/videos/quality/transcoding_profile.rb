module Videos
  class Quality
    class TranscodingProfile < ApplicationRecord
      self.table_name = "videos_qualities_transcoding_profiles"

      belongs_to :quality, class_name: "Videos::Quality"

      validates :label, presence: true, uniqueness: { scope: :quality_id }
      validates :codec, presence: true, uniqueness: { scope: :quality_id }
      validates :bitrate, presence: true, numericality: { only_integer: true, greater_than: 0 }
    end
  end
end
