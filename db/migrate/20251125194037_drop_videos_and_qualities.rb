class DropVideosAndQualities < ActiveRecord::Migration[8.1]
  def change
    drop_table :videos_qualities
  end
end
