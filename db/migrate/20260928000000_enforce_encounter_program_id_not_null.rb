# frozen_string_literal: true

class EnforceEncounterProgramIdNotNull < ActiveRecord::Migration[8.1]
  def up
    null_count = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM encounter
      WHERE program_id IS NULL
    SQL

    if null_count.positive?
      raise ActiveRecord::MigrationError,
            "Cannot enforce encounter.program_id NOT NULL: #{null_count} row(s) still have NULL program_id"
    end

    change_column_null :encounter, :program_id, false
  end

  def down
    change_column_null :encounter, :program_id, true
  end
end
