# frozen_string_literal: true

module AetcMigration
  module Steps
    # orders (AETC lab orders), then their order_extension and lab_lims_order_mappings rows, for patients
    # the encounters step has covered. Runs before obs, so obs get their order_id directly.
    #   * order type from order_type.json (4 'Lab ' -> 6 'Lab'); specimen (concept_id) via concept.json plus
    #     order_type.json specimen_concepts; orders with an unmapped type/specimen are skipped and logged.
    #   * encounter via id_map; orders whose encounter wasn't migrated (incl. AETC 91-93) are skipped.
    #   * empty start_date -> date_created (logged); fractions of seconds are dropped, not rounded.
    #   * orderer/creator/discontinued_by/voided_by -> the AETC user's MaHIS user. AETC-only columns are dropped.
    #   * an accession number MaHIS already uses is loaded and flagged.
    #   * order_extension / lab_lims_order_mappings follow their order (no uuid: id_map makes re-runs
    #     safe); a lims_id MaHIS already has is skipped (the lab engine needs it unique).
    class Orders < PatientBatched
      EXTENSION_VALUE_MAX = 50

      def self.after
        'encounters'
      end

      def title
        'Lab orders'
      end

      def call
        each_patient_batch do |ids, rec|
          migrate_orders(ids)
          orders = sql.select("SELECT order_id, patient_id FROM #{src('orders')} WHERE patient_id IN (#{sql.list(ids)})")
          owner = orders.to_h { |o| [o['order_id'], o['patient_id']] }
          next if owner.empty?

          order_map = mapped_ids('order', owner.keys)
          migrate_extensions(owner, order_map, rec)
          migrate_lims_mappings(owner, order_map, rec)
        end
        counts
      end

      private

      def migrate_orders(ids)
        rows = <<~SQL
          FROM #{src('orders')} o
          JOIN #{trk('id_map')} pm ON pm.entity = 'patient' AND pm.src_id = o.patient_id
          LEFT JOIN #{trk('lookup_order_type')} ot ON ot.source_id = o.order_type_id AND ot.action = 'map'
          LEFT JOIN #{trk('lookup_specimen')} sp ON sp.source_id = o.concept_id
          LEFT JOIN #{trk('id_map')} em ON em.entity = 'encounter' AND em.src_id = o.encounter_id
          WHERE o.patient_id IN (#{sql.list(ids)}) AND #{not_mapped('order', 'o.order_id')}
            AND (o.voided = 0 OR #{owner_voided('o.patient_id')})
        SQL
        loaded = "#{rows} AND ot.target_id IS NOT NULL AND sp.target_id IS NOT NULL AND em.tgt_id IS NOT NULL"
        log_rows("SELECT 'order', o.order_id, 'order_type_unmapped', o.order_type_id #{rows} AND ot.target_id IS NULL")
        log_rows("SELECT 'order', o.order_id, 'specimen_unmapped', o.concept_id #{rows} " \
                 'AND ot.target_id IS NOT NULL AND sp.target_id IS NULL')
        log_rows("SELECT 'order', o.order_id, 'encounter_not_migrated', o.encounter_id #{rows} " \
                 'AND ot.target_id IS NOT NULL AND sp.target_id IS NOT NULL AND em.tgt_id IS NULL')
        log_rows("SELECT 'order', o.order_id, 'start_date_filled', #{dt('o.date_created')} #{loaded} " \
                 "AND #{dt('o.start_date')} IS NULL")
        log_rows("SELECT 'order', o.order_id, 'accession_exists_in_target', o.accession_number #{loaded} " \
                 "AND o.accession_number IS NOT NULL AND EXISTS (SELECT 1 FROM #{tgt('orders')} x " \
                 "WHERE #{sql.same_text(run.target, 'orders', 'accession_number', 'x', 'o')})")
        count('orders', sql.write(<<~SQL))
          INSERT INTO #{tgt('orders')} (order_type_id, concept_id, orderer, encounter_id, instructions, start_date,
            auto_expire_date, discontinued, discontinued_date, discontinued_by, discontinued_reason, creator,
            date_created, voided, voided_by, date_voided, void_reason, patient_id, accession_number, obs_id, uuid,
            discontinued_reason_non_coded, comment_to_fulfiller, fulfiller_comment, fulfiller_status)
          SELECT ot.target_id, sp.target_id, #{run.user_sql('o.orderer')}, em.tgt_id, o.instructions,
            COALESCE(#{whole_seconds('o.start_date')}, #{dt('o.date_created')}), #{dt('o.auto_expire_date')},
            IF(o.discontinued, 1, 0), #{whole_seconds('o.discontinued_date')},
            IF(o.discontinued_by IS NULL, NULL, #{run.user_sql('o.discontinued_by')}), NULL, #{run.user_sql('o.creator')},
            #{dt_required('o.date_created')},
            IF(o.voided, 1, 0), IF(o.voided, #{run.user_sql('o.voided_by')}, NULL), #{dt('o.date_voided')}, o.void_reason, pm.tgt_id,
            o.accession_number, NULL, o.uuid, o.discontinued_reason_non_coded, o.comment_to_fulfiller,
            o.fulfiller_comment, o.fulfiller_status
          #{loaded}
        SQL
        map_by_uuid('order', 'orders', 'order_id', 'orders', 'order_id', "s.patient_id IN (#{sql.list(ids)})")
      end

      # SQL: datetime(6) -> 'YYYY-MM-DD HH:MM:SS', dropping the fraction (MySQL would round it).
      def whole_seconds(column)
        "IF(#{column} >= '1000-01-01', DATE_FORMAT(#{column}, '%Y-%m-%d %H:%i:%s'), NULL)"
      end

      def migrate_extensions(owner, order_map, rec)
        rows = sql.select("SELECT * FROM #{src('order_extension')} WHERE order_id IN (#{sql.list(owner.keys)}) " \
                          'ORDER BY order_extension_id')
        already = mapped_ids('order_extension', rows.map { |r| r['order_extension_id'] })
        owners = voided_owners(owner.values)
        rows.each do |e|
          next if already.key?(e['order_extension_id'])
          next if truthy?(e['voided']) && !owners.include?(owner[e['order_id']])

          order_id = order_map[e['order_id']]
          next rec.logged('order_extension', e['order_extension_id'], 'order_not_migrated', e['order_id']) unless order_id

          value = e['value'].to_s
          if value.length > EXTENSION_VALUE_MAX
            rec.logged('order_extension', e['order_extension_id'], 'value_truncated', value)
            value = value[0, EXTENSION_VALUE_MAX]
          end
          voided = truthy?(e['voided'])
          sql.insert(tgt('order_extension'), [{ 'order_id' => order_id, 'value' => value, 'creator' => run.user_for(e['creator']),
                                                'date_created' => e['date_created'] || EPOCH, 'voided' => voided ? 1 : 0,
                                                'voided_by' => voided ? run.user_for(e['voided_by']) : nil,
                                                'date_voided' => e['date_voided'], 'void_reason' => e['void_reason'] }])
          rec.mapped('order_extension', e, 'order_extension_id', last_insert_id, nil)
          count('order_extension', 1)
        end
      end

      def migrate_lims_mappings(owner, order_map, rec)
        rows = sql.select("SELECT * FROM #{src('lab_lims_order_mappings')} WHERE order_id IN (#{sql.list(owner.keys)}) " \
                          'ORDER BY id')
        already = mapped_ids('lims_order_mapping', rows.map { |r| r['id'] })
        todo = rows.reject { |m| already.key?(m['id']) }
        taken = sql.values("SELECT lims_id FROM #{tgt('lab_lims_order_mappings')} " \
                           "WHERE lims_id IN (#{sql.list(todo.map { |m| m['lims_id'] })})").to_set
        todo.each do |m|
          order_id = order_map[m['order_id']]
          if order_id.nil?
            rec.logged('lims_order_mapping', m['id'], 'order_not_migrated', m['order_id'])
          elsif taken.include?(m['lims_id'])
            rec.logged('lims_order_mapping', m['id'], 'lims_id_exists_in_target', m['lims_id'])
          else
            sql.insert(tgt('lab_lims_order_mappings'),
                       [{ 'lims_id' => m['lims_id'], 'order_id' => order_id, 'pushed_at' => m['pushed_at'],
                          'pulled_at' => m['pulled_at'], 'created_at' => m['created_at'] || EPOCH,
                          'updated_at' => m['updated_at'] || EPOCH, 'revision' => m['revision'],
                          'result_push_status' => m['result_push_status'] }])
            taken << m['lims_id']
            rec.mapped('lims_order_mapping', m, 'id', last_insert_id, nil)
            count('lab_lims_order_mappings', 1)
          end
        end
      end

      def last_insert_id
        sql.value('SELECT LAST_INSERT_ID()').to_i
      end
    end
  end
end
