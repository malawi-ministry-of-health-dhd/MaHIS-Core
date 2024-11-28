class ChangeUserLocationIdForeignKey < ActiveRecord::Migration[7.0]
  def change
    # Remove the previous foreign key if it exists
    if foreign_key_exists?(:users, :location, column: :location_id)
      remove_foreign_key :users, :location
    end

    # Remove the `facility_code` column if it exists
    if column_exists?(:users, :facility_code)
      remove_column :users, :facility_code
    end

    # Ensure location_id column exists with the correct type
    unless column_exists?(:users, :location_id)
      add_column :users, :location_id, :string, null: true
    else
      # Change column type and nullability
      change_column :users, :location_id, :string, null: true
    end

    # Add the new foreign key to the facilities table
    unless foreign_key_exists?(:users, :facilities, column: :location_id)
      add_foreign_key :users, :facilities, 
                      column: :location_id, 
                      primary_key: :code, 
                      type: :string
    end
  end
end