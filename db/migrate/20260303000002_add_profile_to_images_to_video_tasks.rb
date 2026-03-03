class AddProfileToImagesToVideoTasks < ActiveRecord::Migration[8.1]
  def change
    # Add nullable first so existing rows don't immediately violate the constraint
    add_reference :images_to_video_tasks, :images_to_video_profile,
      foreign_key: { to_table: :videos_images_to_video_profiles },
      null: true
  end
end
