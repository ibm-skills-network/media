class CreateTranscodingProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :videos_qualities_transcoding_profiles do |t|
      t.integer :label, null: false
      t.string :codec, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.string :bitrate_string, null: false
      t.integer :bitrate_int, null: false

      t.timestamps
    end
  end
end
