# frozen_string_literal: true

# Adds program_id to the visit table. OpenMRS `visit` has no program column, so
# the dashboards had to infer a visit's program from its encounters — which
# can't attribute an encounter-less (just-started) visit and risks counting
# other programs' visits. Storing the program on the visit lets us count per
# program directly. Existing rows are backfilled from their earliest
# program-bearing encounter.
class AddProgramIdToVisit < ActiveRecord::Migration[8.1]
  def up
    add_column :visit, :program_id, :integer, null: true unless column_exists?(:visit, :program_id)

    unless index_exists?(:visit, :program_id, name: 'idx_visit_program')
      add_index :visit, :program_id, name: 'idx_visit_program'
    end

    # Backfill from the visit's earliest non-voided encounter that carries a program.
    execute(<<~SQL.squish)
      UPDATE visit v
      SET v.program_id = (
        SELECT e.program_id FROM encounter e
        WHERE e.visit_id = v.visit_id AND e.program_id IS NOT NULL AND e.voided = 0
        ORDER BY e.encounter_datetime ASC, e.encounter_id ASC
        LIMIT 1
      )
      WHERE v.program_id IS NULL
    SQL
  end

  def down
    remove_index :visit, name: 'idx_visit_program' if index_exists?(:visit, :program_id, name: 'idx_visit_program')
    remove_column :visit, :program_id if column_exists?(:visit, :program_id)
  end
end
