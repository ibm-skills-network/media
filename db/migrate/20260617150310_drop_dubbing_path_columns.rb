class DropDubbingPathColumns < ActiveRecord::Migration[8.1]
  # Intermediates moved to ActiveStorage so jobs on different worker pods can find each
  # other's outputs, hls_path stays since HLS goes to a controlled COS prefix, not AS
  def change
    remove_column :dubbing_tasks, :audio_path, :string
    remove_column :dubbing_tasks, :source_video_path, :string
    remove_column :dubbing_tasks, :vocals_path, :string
    remove_column :dubbing_tasks, :background_path, :string
    remove_column :dubbing_tasks, :dubbed_audio_path, :string
    remove_column :dubbing_tasks, :dubbed_video_path, :string
  end
end
