class CreateVideosQualities < ActiveRecord::Migration[8.0]
  def change
    create_table :videos_qualities do |t|
      t.references :video, null: false, foreign_key: true
      t.integer :status, default: 0

      t.timestamps
    end
  end
end
