class ChangeConstraintToStringForPharmacyBatch < ActiveRecord::Migration[7.0]
  def change
    # Remove existing foreign key in pharmacy_batches table if it exists
    # Modify the foreign key reference based on your specific relationships
    if foreign_key_exists?(:pharmacy_batches, :location, column: :location_id)
      remove_foreign_key :pharmacy_batches, :location
    end

    # Convert existing location_id to string in pharmacy_batches table
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE pharmacy_batches 
          SET location_id = CAST(location_id AS CHAR) 
          WHERE location_id IS NOT NULL
        SQL
      end

      dir.down do
        execute <<-SQL
          UPDATE pharmacy_batches 
          SET location_id = CAST(location_id AS UNSIGNED) 
          WHERE location_id IS NOT NULL
        SQL
      end
    end

    # Change the column type to string in pharmacy_batches table
    change_column :pharmacy_batches, :location_id, :string, null: true

    # Adding a new foreign key, if necessary, can be uncommented here:
    # reversible do |dir|
    #   dir.up do
    #     add_foreign_key :pharmacy_batches, :facilities, column: :location_id, primary_key: "code", name: "pharmacy_batches_location"
    #   end
    #   dir.down do
    #     remove_foreign_key :pharmacy_batches, :facilities, column: :location_id
    #   end
    # end
  end
end