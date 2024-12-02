class ChangeLocationIdToString < ActiveRecord::Migration[7.0]
  def up
    # Remove existing foreign key if it exists
    if foreign_key_exists?(:encounter, :location, column: :location_id)
      remove_foreign_key :encounter, :location
    end

    # Convert existing location_id to string
    execute <<-SQL
      UPDATE encounter 
      SET location_id = CAST(location_id AS CHAR) 
      WHERE location_id IS NOT NULL
    SQL

    # Change the column type to string
    change_column :encounter, :location_id, :string, null: true

    # Add new foreign key constraint
    # add_foreign_key :encounter, :facilities, column: :location_id, primary_key: "code", name: "encounter_location"
  end

  def down
    # Remove the new foreign key if it exists
    if foreign_key_exists?(:encounter, :facilities, column: :location_id)
      remove_foreign_key :encounter, :facilities
    end

    # Convert back to previous state
    execute <<-SQL
      UPDATE encounter 
      SET location_id = CAST(location_id AS UNSIGNED) 
      WHERE location_id IS NOT NULL
    SQL

    change_column :encounter, :location_id, :integer, null: true

    # Optionally re-add the original foreign key if needed
    add_foreign_key :encounter, :location, column: :location_id
  end
end