class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def up
    unless column_exists?(:users, :facility_code)
      add_column :users, :facility_code, :string, 
        limit: 255, 
        null: true, 
        default: nil, 
        charset: 'utf8mb3', 
        collation: 'utf8mb3_unicode_ci'
    end

    unless index_exists?(:users, :facility_code)
      add_index :users, :facility_code
    end

    execute "ALTER TABLE users DROP FOREIGN KEY fk_users_facility_code" rescue nil

    # Add foreign key
    # execute <<-SQL
    #   ALTER TABLE users
    #   ADD CONSTRAINT fk_users_facility_code
    #   FOREIGN KEY (facility_code)
    #   REFERENCES facilities(code)
    #   ON DELETE SET NULL
    #   ON UPDATE CASCADE
    # SQL
  end

  def down
    execute "ALTER TABLE users DROP FOREIGN KEY fk_users_facility_code" rescue nil
    
    remove_index :users, :facility_code if index_exists?(:users, :facility_code)
    remove_column :users, :facility_code if column_exists?(:users, :facility_code)
  end
end