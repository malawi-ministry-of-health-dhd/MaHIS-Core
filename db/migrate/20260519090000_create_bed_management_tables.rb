class CreateBedManagementTables < ActiveRecord::Migration[8.1]
  def change
    create_bed_table
    create_bed_allocation_table
    add_bed_indexes
    add_bed_allocation_indexes
    add_bed_foreign_keys
    add_bed_allocation_foreign_keys
  end

  private

  def create_bed_table
    return if table_exists?(:bed_mgmt_bed)

    create_table :bed_mgmt_bed, id: false, primary_key: :bed_id do |t|
      t.integer :bed_id, null: false, primary_key: true
      t.string :uuid, limit: 38, null: false
      t.string :bed_number, null: false
      t.string :bed_label
      t.integer :location_id, null: false
      t.integer :facility_id
      t.string :bed_status, null: false, default: 'ACTIVE'
      t.string :bed_type
      t.text :description
      t.integer :creator, null: false
      t.datetime :date_created, null: false
      t.integer :changed_by
      t.datetime :date_changed
      t.boolean :retired, null: false, default: false
      t.integer :retired_by
      t.datetime :date_retired
      t.string :retire_reason
    end
  end

  def create_bed_allocation_table
    return if table_exists?(:bed_mgmt_bed_allocation)

    create_table :bed_mgmt_bed_allocation, id: false, primary_key: :bed_allocation_id do |t|
      t.integer :bed_allocation_id, null: false, primary_key: true
      t.string :uuid, limit: 38, null: false
      t.integer :bed_id, null: false
      t.integer :patient_id, null: false
      t.integer :visit_id
      t.datetime :allocated_at, null: false
      t.datetime :released_at
      t.string :allocation_status, null: false, default: 'ACTIVE'
      t.string :allocation_reason
      t.string :release_reason
      t.text :notes
      t.integer :creator, null: false
      t.datetime :date_created, null: false
      t.integer :changed_by
      t.datetime :date_changed
      t.boolean :voided, null: false, default: false
      t.integer :voided_by
      t.datetime :date_voided
      t.string :void_reason
    end
  end

  def add_bed_indexes
    add_index :bed_mgmt_bed, :uuid, unique: true, name: 'idx_bed_mgmt_bed_uuid' unless index_exists?(
      :bed_mgmt_bed, :uuid, name: 'idx_bed_mgmt_bed_uuid'
    )
    unless index_exists?(:bed_mgmt_bed, %i[location_id bed_number], name: 'idx_bed_mgmt_bed_location_number')
      add_index :bed_mgmt_bed, %i[location_id bed_number], unique: true, name: 'idx_bed_mgmt_bed_location_number'
    end
    unless index_exists?(:bed_mgmt_bed, %i[location_id bed_status retired], name: 'idx_bed_mgmt_bed_location_status')
      add_index :bed_mgmt_bed, %i[location_id bed_status retired], name: 'idx_bed_mgmt_bed_location_status'
    end
  end

  def add_bed_allocation_indexes
    add_index :bed_mgmt_bed_allocation, :uuid, unique: true, name: 'idx_bed_alloc_uuid' unless index_exists?(
      :bed_mgmt_bed_allocation, :uuid, name: 'idx_bed_alloc_uuid'
    )
    unless index_exists?(
      :bed_mgmt_bed_allocation,
      %i[bed_id allocation_status released_at voided],
      name: 'idx_bed_alloc_bed_status_released'
    )
      add_index :bed_mgmt_bed_allocation,
                %i[bed_id allocation_status released_at voided],
                name: 'idx_bed_alloc_bed_status_released'
    end
    add_index :bed_mgmt_bed_allocation, :patient_id, name: 'idx_bed_alloc_patient' unless index_exists?(
      :bed_mgmt_bed_allocation, :patient_id, name: 'idx_bed_alloc_patient'
    )
    add_index :bed_mgmt_bed_allocation, :visit_id, name: 'idx_bed_alloc_visit' unless index_exists?(
      :bed_mgmt_bed_allocation, :visit_id, name: 'idx_bed_alloc_visit'
    )
  end

  def add_bed_foreign_keys
    add_foreign_key :bed_mgmt_bed, :location, column: :location_id, primary_key: :location_id unless foreign_key_exists?(
      :bed_mgmt_bed, :location, column: :location_id
    )
    add_foreign_key :bed_mgmt_bed, :users, column: :creator, primary_key: :user_id unless foreign_key_exists?(
      :bed_mgmt_bed, :users, column: :creator
    )
    add_foreign_key :bed_mgmt_bed, :users, column: :changed_by, primary_key: :user_id unless foreign_key_exists?(
      :bed_mgmt_bed, :users, column: :changed_by
    )
    add_foreign_key :bed_mgmt_bed, :users, column: :retired_by, primary_key: :user_id unless foreign_key_exists?(
      :bed_mgmt_bed, :users, column: :retired_by
    )
  end

  def add_bed_allocation_foreign_keys
    add_foreign_key :bed_mgmt_bed_allocation, :bed_mgmt_bed, column: :bed_id, primary_key: :bed_id unless foreign_key_exists?(
      :bed_mgmt_bed_allocation, :bed_mgmt_bed, column: :bed_id
    )
    add_foreign_key :bed_mgmt_bed_allocation, :patient, column: :patient_id, primary_key: :patient_id unless foreign_key_exists?(
      :bed_mgmt_bed_allocation, :patient, column: :patient_id
    )
    add_foreign_key :bed_mgmt_bed_allocation, :visit, column: :visit_id, primary_key: :visit_id unless foreign_key_exists?(
      :bed_mgmt_bed_allocation, :visit, column: :visit_id
    )
    add_foreign_key :bed_mgmt_bed_allocation, :users, column: :creator, primary_key: :user_id unless foreign_key_exists?(
      :bed_mgmt_bed_allocation, :users, column: :creator
    )
    add_foreign_key :bed_mgmt_bed_allocation, :users, column: :changed_by, primary_key: :user_id unless foreign_key_exists?(
      :bed_mgmt_bed_allocation, :users, column: :changed_by
    )
    add_foreign_key :bed_mgmt_bed_allocation, :users, column: :voided_by, primary_key: :user_id unless foreign_key_exists?(
      :bed_mgmt_bed_allocation, :users, column: :voided_by
    )
  end
end
