class AddLocationIdToRole < ActiveRecord::Migration[8.1]
  def change
    add_column :role, :location_id, :integer unless column_exists?(:role, :location_id)
    add_index :role, :location_id unless index_exists?(:role, :location_id)

    return if foreign_key_exists?(:role, :location, column: :location_id)

    add_foreign_key :role, :location, column: :location_id, primary_key: :location_id
  end
end
