class TranscodingLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :videos_qualities_transcoding_logs do |t|
      t.references :quality, null: false, foreign_key: true
      t.string :label, null: false
      t.string :codec, null: false

      t.timestamps
    end

    add_index :videos_qualities_transcoding_logs, [ :quality_id, :label ], unique: true
    add_index :videos_qualities_transcoding_logs, [ :quality_id, :codec ], unique: true
  end
end
