class VideosQualities < ActiveRecord::Migration[8.0]
  def change
    create_table :videos_qualities do |t|
      t.references :transcoding_profile, null: false, foreign_key: { to_table: :videos_qualities_transcoding_profiles }
      t.integer :status, default: 0
      t.string :external_video_link
      t.timestamps
    end
  end
end
