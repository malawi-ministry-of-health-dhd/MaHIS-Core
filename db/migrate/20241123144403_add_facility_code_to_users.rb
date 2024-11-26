class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    # Create facility_code as a string to match the facilities table
    add_column :users, :facility_code, :string, null: true, default: nil, if_not_exists: true

    add_index :users, :facility_code, if_not_exists: true

    add_foreign_key :users, :facilities, 
      column: :facility_code,
      primary_key: :code, 
      name: 'fk_users_facility_code', 
      if_not_exists: true
  end
end