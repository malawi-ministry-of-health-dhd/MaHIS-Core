# frozen_string_literal: true

module AetcMigration
  module Steps
    # encounter, for patients the visits step has covered.
    #   * encounter type from encounter_type.json; unmapped types are skipped and logged.
    #   * provider_id = the migration user's person; program_id = AETC PROGRAM (30); form_id NULL.
    #   * visit_id via id_map; an encounter whose visit wasn't migrated loads without one (logged).
    #   * location from location.json, as text. AETC 1 "Unknown" becomes 1291 (clinical_overrides, logged)
    #     so Locatable doesn't hide it; any other unmapped location loads as NULL (logged).
    #   * active rows only, except encounters of voided patients (migrated as voided).
    class Encounters < PatientBatched
      def self.after
        'visits'
      end

      def title
        'Encounters'
      end

      def call
        program = run.mappings.aetc_program_id.to_i
        user = run.migration_user_id
        provider = run.migration_person_id
        each_patient_batch do |ids, _rec|
          rows = <<~SQL
            FROM #{src('encounter')} e
            JOIN #{trk('id_map')} pm ON pm.entity = 'patient' AND pm.src_id = e.patient_id
            LEFT JOIN #{trk('lookup_encounter_type')} et ON et.source_id = e.encounter_type AND et.action = 'map'
            LEFT JOIN #{trk('lookup_location')} lo ON lo.scope = 'clinical' AND lo.source_id = e.location_id AND lo.action = 'map'
            LEFT JOIN #{trk('lookup_location')} ld ON ld.scope = 'default' AND ld.source_id = e.location_id AND ld.action = 'map'
            LEFT JOIN #{trk('id_map')} vm ON vm.entity = 'visit' AND vm.src_id = e.visit_id
            WHERE e.patient_id IN (#{sql.list(ids)}) AND #{not_mapped('encounter', 'e.encounter_id')}
              AND (e.voided = 0 OR #{owner_voided('e.patient_id')})
          SQL
          loaded = "#{rows} AND et.target_id IS NOT NULL"
          log_rows("SELECT 'encounter', e.encounter_id, 'encounter_type_unmapped', e.encounter_type #{rows} " \
                   'AND et.target_id IS NULL')
          log_rows("SELECT 'encounter', e.encounter_id, 'location_unmapped', e.location_id #{loaded} " \
                   'AND e.location_id IS NOT NULL AND lo.target_id IS NULL')
          log_rows("SELECT 'encounter', e.encounter_id, 'location_overridden', " \
                   "CONCAT(e.location_id, ' -> ', lo.target_id) #{loaded} AND lo.target_id IS NOT NULL AND ld.source_id IS NULL")
          log_rows("SELECT 'encounter', e.encounter_id, 'visit_not_migrated', e.visit_id #{loaded} " \
                   'AND e.visit_id IS NOT NULL AND vm.tgt_id IS NULL')
          count('encounter', sql.write(<<~SQL))
            INSERT INTO #{tgt('encounter')} (encounter_type, patient_id, provider_id, location_id, form_id,
              encounter_datetime, creator, date_created, voided, voided_by, date_voided, void_reason, uuid,
              changed_by, date_changed, program_id, visit_id)
            SELECT et.target_id, pm.tgt_id, #{provider}, CAST(lo.target_id AS CHAR), NULL,
              #{dt_required('e.encounter_datetime')}, #{user}, #{dt_required('e.date_created')}, IF(e.voided, 1, 0),
              IF(e.voided, #{user}, NULL), #{dt('e.date_voided')}, e.void_reason, e.uuid,
              IF(e.changed_by IS NULL, NULL, #{user}), #{dt('e.date_changed')}, #{program}, vm.tgt_id
            #{loaded}
          SQL
          map_by_uuid('encounter', 'encounter', 'encounter_id', 'encounter', 'encounter_id',
                      "s.patient_id IN (#{sql.list(ids)})")
        end
        counts
      end
    end
  end
end
