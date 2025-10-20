module Videos
  class Quality
    class TranscodingLog < ApplicationRecord
      self.table_name_prefix = "videos_qualities_"

      belongs_to :quality, class_name: "Videos::Quality"

      validates :label, presence: true, uniqueness: { scope: :quality_id }
      validates :codec, presence: true, uniqueness: { scope: :quality_id }
      validates :bitrate, presence: true, numericality: { only_integer: true, greater_than: 0 }
    end
  end
end
