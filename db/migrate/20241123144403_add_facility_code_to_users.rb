class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    # Remove the existing column if it exists
    remove_column :users, :facility_code if column_exists?(:users, :facility_code)
    
    # Add the column with explicit varchar(255) type
    execute "ALTER TABLE users ADD COLUMN facility_code VARCHAR(255) NULL DEFAULT NULL"

    # Add an index
    add_index :users, :facility_code, unique: false

    # Add foreign key using raw SQL to ensure type compatibility
    execute <<-SQL
      ALTER TABLE users
      ADD CONSTRAINT fk_users_facility_code
      FOREIGN KEY (facility_code)
      REFERENCES facilities(code)
    SQL
  end
end