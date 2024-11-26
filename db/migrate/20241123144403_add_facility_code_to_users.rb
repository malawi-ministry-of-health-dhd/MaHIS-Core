class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :facility_code, :string, null: true, default: nil
    add_index :users, :facility_code
    add_foreign_key :users, :facilities, column: :facility_code, primary_key: :code, name: 'fk_users_facility_code'
  end
end
