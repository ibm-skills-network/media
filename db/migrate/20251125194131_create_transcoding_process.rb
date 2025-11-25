class CreateTranscodingProcess < ActiveRecord::Migration[8.1]
  def change
    create_table :videos_qualities_transcoding_processes do |t|
      t.references :transcoding_profile, null: false, foreign_key: { to_table: :videos_qualities_transcoding_profiles }
      t.references :video, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.timestamps
    end
  end
end
