class CreateImagesToVideoTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :images_to_video_tasks do |t|
      t.string :status, null: false, default: "pending"

      t.timestamps
    end
  end
end
