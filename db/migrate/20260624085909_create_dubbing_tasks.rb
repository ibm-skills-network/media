class CreateDubbingTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :dubbing_tasks do |t|
      t.string :video_url, null: false
      t.string :language, null: false
      t.string :dialect
      t.string :hls_path
      t.string :playback_key
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.jsonb :segments, null: false, default: []
      t.jsonb :subtitle_segments, null: false, default: []
      t.jsonb :chapters, null: false, default: []
      t.timestamps

      t.index :playback_key, unique: true
    end
  end
end
