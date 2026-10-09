# frozen_string_literal: true

module AetcMigration
  module Steps
    # obs, for patients the orders step has covered (so encounters and orders are already migrated).
    #   * concept via concept.json; obs whose concept has no MaHIS concept are skipped (concept_unmapped).
    #   * encounter via id_map; obs whose encounter wasn't migrated are skipped.
    #   * coded answers via concept.json; an unmapped answer is kept as text (its AETC name) and logged.
    #   * text_to_coded concepts: the text is looked up in concept.json value maps plus the filled rows of
    #     concept_unmapped_values.csv; a hit becomes value_coded, a miss stays text (logged). Only for
    #     concepts with action map or reviewed = true; others keep the text (conversion_not_reviewed).
    #   * every other value is copied as it is (MaHIS datatype N/A decision).
    #   * obs groups keep their parent; order_id via id_map; location as text (AETC 1 -> 1291).
    #   * active rows only, except obs of voided patients (migrated as voided).
    class Obs < PatientBatched
      PATIENTS_PER_BATCH = 100

      def self.after
        'orders'
      end

      def title
        'Observations'
      end

      def call
        each_patient_batch do |ids, _rec|
          rows = candidates(ids)
          loaded = "#{rows} AND q.target_id IS NOT NULL AND em.tgt_id IS NOT NULL"
          log_skips(rows, loaded)
          count('obs', insert(loaded))
          map_by_uuid('obs', 'obs', 'obs_id', 'obs', 'obs_id', "s.person_id IN (#{sql.list(ids)})")
          link_groups(ids)
        end
        counts
      end

      private

      GATED = "(q.action = 'map' OR q.reviewed = 1)"
      TEXT_TO_CODED = "o.value_text IS NOT NULL AND r.rule = 'text_to_coded'"
      # value_text without leading/trailing whitespace. Only anchored patterns: '[[:space:]]+$' backtracks
      # on long runs of spaces inside a text and hits MySQL's regexp_time_limit, so the end is trimmed by
      # trimming the start of the reversed text.
      TRIMMED_TEXT = "REVERSE(REGEXP_REPLACE(REVERSE(REGEXP_REPLACE(o.value_text, '^[[:space:]]+', '')), " \
                     "'^[[:space:]]+', ''))"

      def candidates(ids)
        <<~SQL
          FROM #{src('obs')} o
          JOIN #{trk('id_map')} pm ON pm.entity = 'patient' AND pm.src_id = o.person_id
          LEFT JOIN #{trk('lookup_concept_question')} q ON q.source_id = o.concept_id
          LEFT JOIN #{trk('id_map')} em ON em.entity = 'encounter' AND em.src_id = o.encounter_id
          LEFT JOIN #{trk('lookup_concept_answer')} a ON a.source_id = o.value_coded
          LEFT JOIN #{trk('lookup_concept_rule')} r ON r.source_id = o.concept_id AND r.value_column = 'value_text'
          LEFT JOIN #{trk('lookup_concept_value')} cv ON cv.source_id = o.concept_id AND #{TEXT_TO_CODED} AND #{GATED}
            AND cv.value_text = CONVERT(#{TRIMMED_TEXT} USING utf8mb4) COLLATE utf8mb4_bin
          LEFT JOIN #{trk('lookup_location')} lo ON lo.scope = 'clinical' AND lo.source_id = o.location_id AND lo.action = 'map'
          LEFT JOIN #{trk('id_map')} om ON om.entity = 'order' AND om.src_id = o.order_id
          WHERE o.person_id IN (#{sql.list(ids)}) AND #{not_mapped('obs', 'o.obs_id')}
            AND (o.voided = 0 OR #{owner_voided('o.person_id')})
        SQL
      end

      def log_skips(rows, loaded)
        log_rows("SELECT 'obs', o.obs_id, 'concept_unmapped', o.concept_id #{rows} AND q.target_id IS NULL")
        log_rows("SELECT 'obs', o.obs_id, 'encounter_not_migrated', o.encounter_id #{rows} " \
                 'AND q.target_id IS NOT NULL AND em.tgt_id IS NULL')
        log_rows("SELECT 'obs', o.obs_id, 'answer_unmapped', CONCAT('AETC answer ', o.value_coded, ' kept as text') " \
                 "#{loaded} AND o.value_coded IS NOT NULL AND a.target_id IS NULL")
        log_rows("SELECT 'obs', o.obs_id, 'conversion_not_reviewed', 'value_text kept' #{loaded} " \
                 "AND #{TEXT_TO_CODED} AND NOT #{GATED}")
        log_rows("SELECT 'obs', o.obs_id, 'value_unmapped', LEFT(o.value_text, 200) #{loaded} " \
                 "AND #{TEXT_TO_CODED} AND #{GATED} AND cv.target_id IS NULL")
        log_rows("SELECT 'obs', o.obs_id, 'value_truncated', 'value_complex' #{loaded} AND CHAR_LENGTH(o.value_complex) > 255")
        log_rows("SELECT 'obs', o.obs_id, 'order_not_migrated', o.order_id #{loaded} " \
                 'AND o.order_id IS NOT NULL AND om.tgt_id IS NULL')
      end

      def insert(loaded)
        user = run.migration_user_id
        sql.write(<<~SQL)
          INSERT INTO #{tgt('obs')} (person_id, concept_id, encounter_id, order_id, obs_datetime, location_id,
            obs_group_id, accession_number, value_group_id, value_boolean, value_coded, value_coded_name_id,
            value_drug, value_datetime, value_numeric, value_modifier, value_text, date_started, date_stopped,
            comments, creator, date_created, voided, voided_by, date_voided, void_reason, value_complex, uuid)
          SELECT pm.tgt_id, q.target_id, em.tgt_id, om.tgt_id, #{dt_required('o.obs_datetime')},
            CAST(lo.target_id AS CHAR), NULL, o.accession_number, NULL, NULL,
            CASE WHEN cv.target_id IS NOT NULL THEN cv.target_id WHEN o.value_coded IS NOT NULL THEN a.target_id END,
            NULL, NULL, #{dt('o.value_datetime')}, o.value_numeric, o.value_modifier,
            CASE WHEN cv.target_id IS NOT NULL THEN NULL
                 WHEN o.value_coded IS NOT NULL AND a.target_id IS NULL AND o.value_text IS NULL
                   THEN COALESCE(NULLIF(a.source_name, ''), CAST(o.value_coded AS CHAR))
                 ELSE o.value_text END,
            NULL, NULL, o.comments, #{user}, #{dt_required('o.date_created')}, IF(o.voided, 1, 0),
            IF(o.voided, #{user}, NULL), #{dt('o.date_voided')}, o.void_reason, LEFT(o.value_complex, 255), o.uuid
          #{loaded}
        SQL
      end

      # Points each migrated child at its migrated parent; children whose parent was not migrated
      # keep no group and are logged.
      def link_groups(ids)
        joins = <<~SQL
          #{src('obs')} s
          JOIN #{trk('id_map')} cm ON cm.entity = 'obs' AND cm.src_id = s.obs_id
          JOIN #{tgt('obs')} t ON t.obs_id = cm.tgt_id
          LEFT JOIN #{trk('id_map')} gm ON gm.entity = 'obs' AND gm.src_id = s.obs_group_id
        SQL
        children = "s.person_id IN (#{sql.list(ids)}) AND s.obs_group_id IS NOT NULL AND t.obs_group_id IS NULL"
        sql.write("UPDATE #{joins} SET t.obs_group_id = gm.tgt_id WHERE #{children} AND gm.tgt_id IS NOT NULL")
        log_rows("SELECT 'obs', s.obs_id, 'group_parent_not_migrated', s.obs_group_id FROM #{joins} " \
                 "WHERE #{children} AND gm.tgt_id IS NULL")
      end
    end
  end
end
