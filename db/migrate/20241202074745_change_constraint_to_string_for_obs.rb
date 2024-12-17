class ChangeConstraintToStringForObs < ActiveRecord::Migration[7.0]
  def change
    # Remove existing foreign key in obs table if it exists
    if foreign_key_exists?(:obs, :location, column: :location_id)
      remove_foreign_key :obs, :location
    end

    # Convert existing location_id to string in obs table
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE obs 
          SET location_id = CAST(location_id AS CHAR) 
          WHERE location_id IS NOT NULL
        SQL
      end

      dir.down do
        execute <<-SQL
          UPDATE obs 
          SET location_id = CAST(location_id AS UNSIGNED) 
          WHERE location_id IS NOT NULL
        SQL
      end
    end

    # Change the column type to string in obs table
    change_column :obs, :location_id, :string, null: true

    # Adding a new foreign key, if necessary, can be uncommented here:
    # reversible do |dir|
    #   dir.up do
    #     add_foreign_key :obs, :facilities, column: :location_id, primary_key: "code", name: "obs_location"
    #   end
    #   dir.down do
    #     remove_foreign_key :obs, :facilities, column: :location_id
    #   end
    # end
  end
end
