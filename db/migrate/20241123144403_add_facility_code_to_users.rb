class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    # Remove the column if it exists
    remove_column :users, :facility_code if column_exists?(:users, :facility_code)
    
    # Then add the column
    add_column :users, :facility_code, :string, null: true, default: nil

    add_index :users, :facility_code, unique: false, if_not_exists: true

    add_foreign_key :users, :facilities, 
      column: :facility_code,
      primary_key: :code, 
      name: 'fk_users_facility_code'
  end
end