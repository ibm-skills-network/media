class AddComputeTimeToImagesToVideoTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :images_to_video_tasks, :completion_time, :integer
  end
end
