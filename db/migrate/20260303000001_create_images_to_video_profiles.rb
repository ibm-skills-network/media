class CreateImagesToVideoProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :videos_images_to_video_profiles do |t|
      t.integer :label,        null: false
      t.string  :codec,        null: false
      t.string  :audio_codec,  null: false
      t.string  :container,    null: false
      t.jsonb   :extra_video_options, null: false, default: []

      t.timestamps
    end
  end
end
