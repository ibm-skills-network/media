class AddStatusToVideo < ActiveRecord::Migration[8.1]
  def change
    add_column :videos, :status, :string, default: "processing"
  end
end
