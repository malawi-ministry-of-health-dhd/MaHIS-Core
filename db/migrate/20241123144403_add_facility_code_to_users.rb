class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    # Add facility_code column with appropriate constraints for your users table
    add_column :users, :facility_code, :string, null: true, default: nil

    add_index :users, :facility_code, unique: false, if_not_exists: true

    # Use the correct primary key for the users table
    add_foreign_key :users, :facilities, 
      column: :facility_code,
      primary_key: :code, 
      name: 'fk_users_facility_code'
  end
end