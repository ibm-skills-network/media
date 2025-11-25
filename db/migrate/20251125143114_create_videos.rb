class CreateVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :videos do |t|
      t.string :external_video_link
      t.timestamps
    end

    change_table :videos_qualities do |t|
      t.references :video, null: false, foreign_key: true
      t.remove :external_video_link
    end
  end
end
