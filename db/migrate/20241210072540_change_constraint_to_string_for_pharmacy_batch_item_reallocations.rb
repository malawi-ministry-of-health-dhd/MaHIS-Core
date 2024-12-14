class ChangeConstraintToStringForPharmacyBatchItemReallocations < ActiveRecord::Migration[7.0]
  def change
    # Remove the existing foreign key in pharmacy_batch_item_reallocations table if it exists
    if foreign_key_exists?(:pharmacy_batch_item_reallocations, :locations, column: :location_id)
      remove_foreign_key :pharmacy_batch_item_reallocations, :locations
    end

    # Ensure location_id column exists and is of the correct type (string, varchar(255))
    unless column_exists?(:pharmacy_batch_item_reallocations, :location_id)
      add_column :pharmacy_batch_item_reallocations, :location_id, :string, limit: 255, null: true
    else
      # Change column type to string to match updated requirements
      change_column :pharmacy_batch_item_reallocations, :location_id, :string, limit: 255, null: true
    end

    # Convert existing integer location_id values to string (up migration)
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE pharmacy_batch_item_reallocations
          SET location_id = CAST(location_id AS CHAR)
          WHERE location_id IS NOT NULL
        SQL
      end

      dir.down do
        execute <<-SQL
          UPDATE pharmacy_batch_item_reallocations
          SET location_id = CAST(location_id AS UNSIGNED)
          WHERE location_id IS NOT NULL
        SQL
      end
    end

    # Add the new foreign key (commented out for now)
    # Uncomment and adjust if you need the foreign key in the future
    # add_foreign_key :pharmacy_batch_item_reallocations, :locations,
    #                 column: :location_id,
    #                 primary_key: :code,
    #                 type: :string
  end
end
