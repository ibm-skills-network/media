class CreateVideos < ActiveRecord::Migration[8.0]
  def change
    create_table :videos do |t|
      t.string :external_video_link

      t.timestamps
    end
  end
end
