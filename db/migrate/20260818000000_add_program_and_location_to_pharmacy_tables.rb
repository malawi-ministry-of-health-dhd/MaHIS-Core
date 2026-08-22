# frozen_string_literal: true

class AddProgramAndLocationToPharmacyTables < ActiveRecord::Migration[7.0]
  def change
    # Add program_id and location_id to drug_cms
    add_column :drug_cms, :program_id, :integer, null: true unless column_exists?(:drug_cms, :program_id)
    add_column :drug_cms, :location_id, :string, null: true unless column_exists?(:drug_cms, :location_id)
    add_index :drug_cms, :program_id unless index_exists?(:drug_cms, :program_id)
    add_index :drug_cms, :location_id unless index_exists?(:drug_cms, :location_id)
    add_index :drug_cms, [:program_id, :location_id], name: 'index_drug_cms_on_program_and_location' unless index_exists?(:drug_cms, [:program_id, :location_id], name: 'index_drug_cms_on_program_and_location')

    # Add program_id to pharmacy_batches (location_id already exists)
    add_column :pharmacy_batches, :program_id, :integer, null: true unless column_exists?(:pharmacy_batches, :program_id)
    add_index :pharmacy_batches, :program_id unless index_exists?(:pharmacy_batches, :program_id)
    add_index :pharmacy_batches, [:program_id, :location_id], name: 'index_pharmacy_batches_on_program_and_location' unless index_exists?(:pharmacy_batches, [:program_id, :location_id], name: 'index_pharmacy_batches_on_program_and_location')

    # Add program_id and location_id to pharmacy_batch_items
    add_column :pharmacy_batch_items, :program_id, :integer, null: true unless column_exists?(:pharmacy_batch_items, :program_id)
    add_column :pharmacy_batch_items, :location_id, :string, null: true unless column_exists?(:pharmacy_batch_items, :location_id)
    add_index :pharmacy_batch_items, :program_id unless index_exists?(:pharmacy_batch_items, :program_id)
    add_index :pharmacy_batch_items, :location_id unless index_exists?(:pharmacy_batch_items, :location_id)
    add_index :pharmacy_batch_items, [:program_id, :location_id], name: 'index_pharmacy_batch_items_on_program_and_location' unless index_exists?(:pharmacy_batch_items, [:program_id, :location_id], name: 'index_pharmacy_batch_items_on_program_and_location')

    # Add program_id to pharmacy_batch_item_reallocations (location_id already exists)
    add_column :pharmacy_batch_item_reallocations, :program_id, :integer, null: true unless column_exists?(:pharmacy_batch_item_reallocations, :program_id)
    add_index :pharmacy_batch_item_reallocations, :program_id unless index_exists?(:pharmacy_batch_item_reallocations, :program_id)
    add_index :pharmacy_batch_item_reallocations, [:program_id, :location_id], name: 'index_pharmacy_batch_reallocations_on_prog_and_loc' unless index_exists?(:pharmacy_batch_item_reallocations, [:program_id, :location_id], name: 'index_pharmacy_batch_reallocations_on_prog_and_loc')

    # Add program_id and location_id to pharmacy_stock_verifications
    add_column :pharmacy_stock_verifications, :program_id, :integer, null: true unless column_exists?(:pharmacy_stock_verifications, :program_id)
    add_column :pharmacy_stock_verifications, :location_id, :string, null: true unless column_exists?(:pharmacy_stock_verifications, :location_id)
    add_index :pharmacy_stock_verifications, :program_id unless index_exists?(:pharmacy_stock_verifications, :program_id)
    add_index :pharmacy_stock_verifications, :location_id unless index_exists?(:pharmacy_stock_verifications, :location_id)
    add_index :pharmacy_stock_verifications, [:program_id, :location_id], name: 'index_pharmacy_stock_verif_on_program_and_location' unless index_exists?(:pharmacy_stock_verifications, [:program_id, :location_id], name: 'index_pharmacy_stock_verif_on_program_and_location')

    # Add program_id and location_id to pharmacy_obs
    add_column :pharmacy_obs, :program_id, :integer, null: true unless column_exists?(:pharmacy_obs, :program_id)
    add_column :pharmacy_obs, :location_id, :string, null: true unless column_exists?(:pharmacy_obs, :location_id)
    add_index :pharmacy_obs, :program_id unless index_exists?(:pharmacy_obs, :program_id)
    add_index :pharmacy_obs, :location_id unless index_exists?(:pharmacy_obs, :location_id)
    add_index :pharmacy_obs, [:program_id, :location_id], name: 'index_pharmacy_obs_on_program_and_location' unless index_exists?(:pharmacy_obs, [:program_id, :location_id], name: 'index_pharmacy_obs_on_program_and_location')

    # Add foreign key constraints only if they don't exist
    unless foreign_key_exists?(:drug_cms, :program, column: :program_id)
      add_foreign_key :drug_cms, :program, column: :program_id, primary_key: :program_id, on_delete: :nullify
    end
    
    unless foreign_key_exists?(:pharmacy_batches, :program, column: :program_id)
      add_foreign_key :pharmacy_batches, :program, column: :program_id, primary_key: :program_id, on_delete: :nullify
    end
    
    unless foreign_key_exists?(:pharmacy_batch_items, :program, column: :program_id)
      add_foreign_key :pharmacy_batch_items, :program, column: :program_id, primary_key: :program_id, on_delete: :nullify
    end
    
    unless foreign_key_exists?(:pharmacy_batch_item_reallocations, :program, column: :program_id)
      add_foreign_key :pharmacy_batch_item_reallocations, :program, column: :program_id, primary_key: :program_id, on_delete: :nullify
    end
    
    unless foreign_key_exists?(:pharmacy_stock_verifications, :program, column: :program_id)
      add_foreign_key :pharmacy_stock_verifications, :program, column: :program_id, primary_key: :program_id, on_delete: :nullify
    end
    
    unless foreign_key_exists?(:pharmacy_obs, :program, column: :program_id)
      add_foreign_key :pharmacy_obs, :program, column: :program_id, primary_key: :program_id, on_delete: :nullify
    end
  end
end
