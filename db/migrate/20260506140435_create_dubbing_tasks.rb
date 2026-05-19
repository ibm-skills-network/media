class CreateDubbingTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :dubbing_tasks do |t|
      t.string :video_url, null: false
      t.string :language, null: false
      t.string :dialect
      t.string :audio_path
      t.string :vocals_path
      t.string :background_path
      t.string :dubbed_audio_path
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.jsonb :segments, null: false, default: []
      t.jsonb :chapters, null: false, default: []
      t.timestamps
    end
  end
end
