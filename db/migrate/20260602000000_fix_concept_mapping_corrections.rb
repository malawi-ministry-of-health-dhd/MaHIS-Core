# frozen_string_literal: true

# Corrects obs rows that were migrated using wrong TB answer concept IDs.
#
# BHT source concept 7455 (TB Suspected answer) was originally mapped to
# MaHIS concept 55562 ("sup") instead of 55563 ("TB Suspected").
# BHT source concept 7458 (Confirmed TB on Treatment answer) was originally
# mapped to MaHIS concept 55567 ("Rx") instead of 55568 ("Confirmed TB on treatment").
#
# These were the only 2 changes made to db/concept_id_mapping.json that did
# not already have a corresponding data-fix migration. The mapping file was
# corrected (7455→55563, 7458→55568) but the migrated obs rows still hold
# the old wrong value_coded values and need to be updated here.
class FixConceptMappingCorrections < ActiveRecord::Migration[8.1]
  # TB status question concept in MaHIS
  TB_STATUS_CONCEPT_ID = 55_569

  def up
    # Fix TB Suspected answer: 55562 ("sup") → 55563 ("TB Suspected")
    execute <<~SQL
      UPDATE obs
      SET value_coded = 55563
      WHERE value_coded = 55562
        AND concept_id = #{TB_STATUS_CONCEPT_ID}
        AND voided = 0
    SQL
    say "TB Suspected (55562→55563): #{select_value('SELECT ROW_COUNT()')} obs updated"

    # Fix Confirmed TB on Treatment answer: 55567 ("Rx") → 55568 ("Confirmed TB on treatment")
    execute <<~SQL
      UPDATE obs
      SET value_coded = 55568
      WHERE value_coded = 55567
        AND concept_id = #{TB_STATUS_CONCEPT_ID}
        AND voided = 0
    SQL
    say "Confirmed TB on Treatment (55567→55568): #{select_value('SELECT ROW_COUNT()')} obs updated"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Cannot reverse — original (incorrect) concept IDs are not stored'
  end
end
