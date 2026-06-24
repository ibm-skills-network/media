class AddPlaybackKeyToDubbingTasks < ActiveRecord::Migration[8.1]
  # Random per-task token included in the HLS URL prefix so the bucket can be
  # publicly readable without making URLs guessable from sequential task ids
  def change
    add_column :dubbing_tasks, :playback_key, :string
    add_index :dubbing_tasks, :playback_key, unique: true
  end
end
