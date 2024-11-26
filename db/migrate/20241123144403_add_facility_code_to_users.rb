class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :facility_code, :string, limit: 255, null: true, default: nil, if_not_exists: true
    add_index :users, :facility_code, if_not_exists: true
    add_foreign_key :users, :facilities, column: :facility_code, primary_key: :code, name: 'fk_users_facility_code', if_not_exists: true
  end
end