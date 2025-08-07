class AddLocationIdToGlobalProperty < ActiveRecord::Migration[7.0]
  def change
    add_column :global_property, :location_id, :string,limit: 255, 
        null: true, 
        default: nil, 
        charset: 'utf8mb3', 
        collation: 'utf8mb3_unicode_ci'
    
    execute "ALTER TABLE global_property DROP PRIMARY KEY"
    
    add_column :global_property, :id, :bigint, auto_increment: true, primary_key: true, first: true
    
    add_index :global_property, [:property, :location_id], 
              unique: true, 
              name: 'idx_global_property_property_location'
    
  end
end

