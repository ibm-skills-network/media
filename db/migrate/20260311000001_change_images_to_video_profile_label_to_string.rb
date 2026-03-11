class ChangeImagesToVideoProfileLabelToString < ActiveRecord::Migration[8.0]
  def up
    remove_column :videos_images_to_video_profiles, :label
  end
end
