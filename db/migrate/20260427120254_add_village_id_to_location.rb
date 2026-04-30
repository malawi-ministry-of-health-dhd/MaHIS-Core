class AddVillageIdToLocation < ActiveRecord::Migration[8.1]
  def change
    add_column :location, :village_id, :integer
  end
end
