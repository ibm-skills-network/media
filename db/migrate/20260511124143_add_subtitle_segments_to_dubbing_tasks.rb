class AddSubtitleSegmentsToDubbingTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :dubbing_tasks, :subtitle_segments, :jsonb, default: [], null: false
  end
end
