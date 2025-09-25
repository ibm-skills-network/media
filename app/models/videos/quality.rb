module Videos
  class Quality < ApplicationRecord
    self.table_name_prefix = "videos_"

    belongs_to :video
    has_one_attached :video_file

    enum :quality, { "480p" => 0, "720p" => 1, "1080p" => 2 }
    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3, unavailable: 4 }, default: :pending

    validates :quality, presence: true, inclusion: { in: qualities.keys }
    validates :status, presence: true, inclusion: { in: statuses.keys }
  end
end
