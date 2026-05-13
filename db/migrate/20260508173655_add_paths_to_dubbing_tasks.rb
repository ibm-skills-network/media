class AddPathsToDubbingTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :dubbing_tasks, :dubbed_video_path, :string
    add_column :dubbing_tasks, :hls_path, :string
  end
end
