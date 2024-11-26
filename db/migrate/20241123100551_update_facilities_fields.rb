class UpdateFacilitiesFields < ActiveRecord::Migration[7.0]
  def change
    # Facility.delete_all
    # Change data types for existing columns
    change_column :facilities, :latitude, :decimal, precision: 10, scale: 6
    change_column :facilities, :longitude, :decimal, precision: 10, scale: 6

    # Remove columns if no longer needed
    # remove_column :facilities, :some_old_column, :string
  end
end
