class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :facility_code, :string, limit: 255, null: true, default: nil, if_not_exists: true

    # Set the collation of the `facility_code` column to match `facilities.code`
    execute <<-SQL.squish
      ALTER TABLE users
      MODIFY facility_code VARCHAR(255)
      CHARACTER SET utf8mb4
      COLLATE utf8mb4_0900_ai_ci
    SQL

    add_index :users, :facility_code, if_not_exists: true
    add_foreign_key :users, :facilities, column: :facility_code, primary_key: :code, name: 'fk_users_facility_code', if_not_exists: true
  end
end