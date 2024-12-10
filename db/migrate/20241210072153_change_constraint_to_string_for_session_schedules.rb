class ChangeConstraintToStringForSessionSchedules < ActiveRecord::Migration[7.0]
  def change
    # Remove the existing foreign key in session_schedules table if it exists
    if foreign_key_exists?(:session_schedules, :locations, column: :location_id)
      remove_foreign_key :session_schedules, :locations
    end

    # Ensure location_id column exists and is of the correct type (string, varchar(255))
    unless column_exists?(:session_schedules, :location_id)
      add_column :session_schedules, :location_id, :string, limit: 255, null: true
    else
      # Change column type to string to match updated requirements
      change_column :session_schedules, :location_id, :string, limit: 255, null: true
    end

    # Convert existing integer location_id values to string (up migration)
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE session_schedules
          SET location_id = CAST(location_id AS CHAR)
          WHERE location_id IS NOT NULL
        SQL
      end

      dir.down do
        execute <<-SQL
          UPDATE session_schedules
          SET location_id = CAST(location_id AS UNSIGNED)
          WHERE location_id IS NOT NULL
        SQL
      end
    end

    # Add the new foreign key (commented out for now)
    # Uncomment and adjust if you need the foreign key in the future
    # add_foreign_key :session_schedules, :locations,
    #                 column: :location_id,
    #                 primary_key: :code,
    #                 type: :string
  end
end
