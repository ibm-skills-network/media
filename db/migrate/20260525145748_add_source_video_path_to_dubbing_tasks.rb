class AddSourceVideoPathToDubbingTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :dubbing_tasks, :source_video_path, :string
  end
end
