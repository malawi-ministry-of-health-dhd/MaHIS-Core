class ChangeLocationIdToStringForObs < ActiveRecord::Migration[7.0]
  def up
    # Remove existing foreign key from encounter table if it exists
    if foreign_key_exists?(:encounter, :locations, column: :location_id)
      remove_foreign_key :encounter, :locations
    end

    # Convert existing location_id to string in the encounter table
    execute <<-SQL
      UPDATE encounter
      SET location_id = CAST(location_id AS CHAR)
      WHERE location_id IS NOT NULL
    SQL

    # Change the column type to string in the encounter table
    change_column :encounter, :location_id, :string, limit: 255, null: true

    # Add the new foreign key (commented out for now)
    # Uncomment and adjust if needed in the future
    # add_foreign_key :encounter, :facilities,
    #                 column: :location_id,
    #                 primary_key: :code,
    #                 type: :string
  end

  def down
    # Remove the new foreign key if it exists
    if foreign_key_exists?(:encounter, :facilities, column: :location_id)
      remove_foreign_key :encounter, :facilities
    end

    # Convert location_id back to integer in the encounter table
    execute <<-SQL
      UPDATE encounter
      SET location_id = CAST(location_id AS UNSIGNED)
      WHERE location_id IS NOT NULL
    SQL

    # Revert the column type to integer in the encounter table
    change_column :encounter, :location_id, :integer, null: true

    # Optionally re-add the original foreign key if needed
    add_foreign_key :encounter, :locations, column: :location_id
  end
end
