class RenameBedFacilityIdToLocationId < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:bed_mgmt_bed)

    rename_column :bed_mgmt_bed, :facility_id, :location_id if column_exists?(:bed_mgmt_bed, :facility_id)
    add_bed_location_foreign_key
  end

  def down
    return unless table_exists?(:bed_mgmt_bed)

    remove_bed_location_foreign_key
    rename_column :bed_mgmt_bed, :location_id, :facility_id if column_exists?(:bed_mgmt_bed, :location_id)
  end

  private

  def add_bed_location_foreign_key
    return unless column_exists?(:bed_mgmt_bed, :location_id)
    return if foreign_key_exists?(:bed_mgmt_bed, :location, column: :location_id)

    add_foreign_key :bed_mgmt_bed, :location, column: :location_id, primary_key: :location_id
  end

  def remove_bed_location_foreign_key
    return unless foreign_key_exists?(:bed_mgmt_bed, :location, column: :location_id)

    remove_foreign_key :bed_mgmt_bed, column: :location_id
  end
end
