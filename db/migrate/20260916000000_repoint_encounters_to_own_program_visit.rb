# frozen_string_literal: true

# Repoints encounters that were filed under another programme's visit.
#
# EncounterService#create used to resolve a visit with
# `Visit.find_by(patient_id:, date_stopped: nil)` — any open visit, ignoring the
# programme, and unordered, so the database returned the oldest still-open one.
# A patient with a stale open OPD visit therefore had their AETC, HTS, IPD and
# NCD encounters all recorded against that OPD visit, and anything grouping a
# patient record by visit mixed the programmes together. That lookup is now
# scoped to the encounter's own programme.
#
# This corrects the rows already written. An encounter is only moved when its
# own programme has a visit whose window contains the encounter datetime;
# everything else is left exactly as it is and reported, because a programme
# that never opens visits (IMMUNIZATION, NCD, HIV) has nothing to move it to and
# clearing the column would discard information rather than correct it.
class RepointEncountersToOwnProgramVisit < ActiveRecord::Migration[8.1]
  def up
    rows = select_all(<<~SQL).to_a
      SELECT e.encounter_id,
             e.visit_id AS current_visit_id,
             (SELECT c.visit_id
                FROM visit c
               WHERE c.patient_id = e.patient_id
                 AND c.program_id = e.program_id
                 AND c.voided = 0
                 AND e.encounter_datetime >= c.date_started
                 AND (c.date_stopped IS NULL OR e.encounter_datetime <= c.date_stopped)
               ORDER BY c.date_started DESC
               LIMIT 1) AS correct_visit_id
        FROM encounter e
        JOIN visit v ON v.visit_id = e.visit_id AND v.voided = 0
       WHERE e.voided = 0
         AND e.program_id <> v.program_id
    SQL

    movable = rows.select { |row| row['correct_visit_id'] && row['correct_visit_id'] != row['current_visit_id'] }
    skipped = rows.size - movable.size

    # Printed so the original attribution stays recoverable from the migration
    # log: the change itself cannot be reversed automatically.
    movable.each do |row|
      say "encounter #{row['encounter_id']}: visit #{row['current_visit_id']} -> #{row['correct_visit_id']}", true
    end

    movable.each_slice(200) do |batch|
      cases = batch.map { |row| "WHEN #{row['encounter_id'].to_i} THEN #{row['correct_visit_id'].to_i}" }.join(' ')
      ids = batch.map { |row| row['encounter_id'].to_i }.join(',')
      execute <<~SQL
        UPDATE encounter
           SET visit_id = CASE encounter_id #{cases} END
         WHERE encounter_id IN (#{ids})
      SQL
    end

    say "Repointed #{movable.size} encounter(s) to their own programme's visit"
    say "Left #{skipped} encounter(s) unchanged: their programme has no visit covering that time"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Original visit attributions are only recorded in the up-migration log'
  end
end
