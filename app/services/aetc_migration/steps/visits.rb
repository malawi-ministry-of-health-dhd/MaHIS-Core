# frozen_string_literal: true

module AetcMigration
  module Steps
    # visit -> the MaHIS visit table, for patients the patients step has migrated.
    #   * visit type from visit_type.json; unmapped types are skipped and logged.
    #   * location from location.json; an unmapped location (AETC 1 "Unknown") loads as NULL (logged).
    #   * program_id = AETC PROGRAM (30); open visits stay open.
    #   * active rows only, except visits of voided patients (migrated as voided).
    class Visits < PatientBatched
      PATIENTS_PER_BATCH = 1000

      def self.after
        'patients'
      end

      def title
        'Visits'
      end

      def call
        program = run.mappings.aetc_program_id.to_i
        user = run.migration_user_id
        each_patient_batch do |ids, _rec|
          rows = <<~SQL
            FROM #{src('visit')} v
            JOIN #{trk('id_map')} pm ON pm.entity = 'patient' AND pm.src_id = v.patient_id
            LEFT JOIN #{trk('lookup_visit_type')} vt ON vt.source_id = v.visit_type_id AND vt.action = 'map'
            LEFT JOIN #{trk('lookup_location')} lo ON lo.scope = 'default' AND lo.source_id = v.location_id AND lo.action = 'map'
            WHERE v.patient_id IN (#{sql.list(ids)}) AND #{not_mapped('visit', 'v.visit_id')}
              AND (v.voided = 0 OR #{owner_voided('v.patient_id')})
          SQL
          log_rows("SELECT 'visit', v.visit_id, 'visit_type_unmapped', v.visit_type_id #{rows} AND vt.target_id IS NULL")
          log_rows("SELECT 'visit', v.visit_id, 'location_unmapped', v.location_id #{rows} " \
                   'AND vt.target_id IS NOT NULL AND v.location_id IS NOT NULL AND lo.target_id IS NULL')
          count('visit', sql.write(<<~SQL))
            INSERT INTO #{tgt('visit')} (patient_id, visit_type_id, indication_concept_id, location_id, date_started,
              date_stopped, voided, voided_by, date_voided, void_reason, creator, date_created, changed_by,
              date_changed, uuid, program_id)
            SELECT pm.tgt_id, vt.target_id, NULL, lo.target_id, #{dt_required('v.date_started')},
              #{dt('v.date_stopped')}, IF(v.voided, 1, 0), IF(v.voided, #{user}, NULL), #{dt('v.date_voided')},
              v.void_reason, #{user}, #{dt_required('v.date_created')}, IF(v.changed_by IS NULL, NULL, #{user}),
              #{dt('v.date_changed')}, v.uuid, #{program}
            #{rows} AND vt.target_id IS NOT NULL
          SQL
          map_by_uuid('visit', 'visit', 'visit_id', 'visit', 'visit_id', "s.patient_id IN (#{sql.list(ids)})")
        end
        counts
      end
    end
  end
end
