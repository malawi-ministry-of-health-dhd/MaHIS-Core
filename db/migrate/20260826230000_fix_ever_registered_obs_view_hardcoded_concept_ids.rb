# frozen_string_literal: true

# The `ever_registered_obs` view (originally ported from BHT-EMR-API's structure.sql)
# hardcoded concept_id = 7937 (Ever registered at ART clinic) and value_coded = 1065 (Yes).
# Those numeric IDs are specific to BHT-EMR-API's concept dictionary. In mahis_backend's
# dictionary, 7937 maps to an unrelated concept ("Other specified primary biliary
# cholangitis") and 1065 is not "Yes" either, so the view silently returned zero rows,
# breaking re_initiated_check() for every patient (e.g. mis-classifying re-initiated
# pregnant patients as newly-pregnant in the cohort report).
#
# Fix: rebuild the view to resolve concept IDs by name via a subquery instead of a
# literal number. This makes the view correct on any environment/database — the
# production DB right now, and any freshly initialized database in future — since it
# no longer depends on concept dictionary numbering matching BHT's.
class FixEverRegisteredObsViewHardcodedConceptIds < ActiveRecord::Migration[8.1]
  EVER_REGISTERED_CONCEPT_NAME = 'Ever registered at ART clinic'
  YES_CONCEPT_NAME = 'Yes'

  def up
    execute 'DROP VIEW IF EXISTS ever_registered_obs'
    execute <<~SQL
      CREATE VIEW ever_registered_obs AS
      SELECT obs.*
      FROM obs
      WHERE obs.voided = 0
        AND obs.concept_id = (
          SELECT concept_id FROM concept_name
          WHERE name = #{quote(EVER_REGISTERED_CONCEPT_NAME)} AND voided = 0
          LIMIT 1
        )
        AND obs.value_coded = (
          SELECT concept_id FROM concept_name
          WHERE name = #{quote(YES_CONCEPT_NAME)} AND voided = 0
          LIMIT 1
        )
    SQL
  end

  def down
    execute 'DROP VIEW IF EXISTS ever_registered_obs'
    execute <<~SQL
      CREATE VIEW ever_registered_obs AS
      SELECT obs.*
      FROM obs
      WHERE obs.concept_id = 7937 AND obs.voided = 0 AND obs.value_coded = 1065
    SQL
  end
end
