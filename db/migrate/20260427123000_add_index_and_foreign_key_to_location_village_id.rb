class AddIndexAndForeignKeyToLocationVillageId < ActiveRecord::Migration[8.1]
  def change
    add_index :location, :village_id unless index_exists?(:location, :village_id)

    add_foreign_key :location, :location,
                    column: :village_id,
                    primary_key: :location_id,
                    unless_exists: true
  end
end
