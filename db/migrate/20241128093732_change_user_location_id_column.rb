class ChangeUserLocationIdColumn < ActiveRecord::Migration[7.0]
  def change
    unless column_exists?(:users, :location_id)
      add_column :users, :location_id, :string, limit: 255, null: true
    else
      change_column :users, :location_id, :string, limit: 255, null: true
    end
  end
end
