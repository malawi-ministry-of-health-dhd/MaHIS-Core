# frozen_string_literal: true

# Triage clients have always recorded the colour as a "Triage Result"
# observation. Stage writes previously discarded the same value, leaving active
# AETC queue rows blank. Backfill those rows so patients who were triaged before
# the persistence fix also display their category.
class BackfillStageTriageResults < ActiveRecord::Migration[8.1]
  def up
    concept_ids = select_values(<<~SQL.squish).map(&:to_i)
      SELECT DISTINCT concept_id
      FROM concept_name
      WHERE LOWER(name) = 'triage result'
        AND voided = 0
    SQL
    return if concept_ids.empty?

    stage_rows = select_all(<<~SQL.squish)
      SELECT id, visit_id
      FROM stages
      WHERE status = 1
        AND (triage_result IS NULL OR TRIM(triage_result) = '')
    SQL

    stage_rows.each do |stage|
      result = select_value(<<~SQL.squish)
        SELECT obs.value_text
        FROM obs
        INNER JOIN encounter ON encounter.encounter_id = obs.encounter_id
        WHERE encounter.visit_id = #{connection.quote(stage['visit_id'])}
          AND obs.concept_id IN (#{concept_ids.join(',')})
          AND obs.voided = 0
          AND LOWER(TRIM(obs.value_text)) IN ('red', 'yellow', 'green', 'emergency', 'priority', 'queue')
        ORDER BY obs.obs_datetime DESC, obs.obs_id DESC
        LIMIT 1
      SQL
      next if result.blank?

      execute <<~SQL.squish
        UPDATE stages
        SET triage_result = #{connection.quote(result)}
        WHERE id = #{connection.quote(stage['id'])}
      SQL
    end
  end

  def down
    # The source observations remain authoritative; do not erase legitimate
    # triage data if this migration is rolled back.
  end
end
