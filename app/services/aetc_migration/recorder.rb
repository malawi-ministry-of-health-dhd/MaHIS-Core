# frozen_string_literal: true

module AetcMigration
  # Collects what one batch did, and writes it to the tracking schema in the batch's transaction:
  #   mapped  -> id_map (AETC id -> MaHIS id, plus the original AETC creator/changed_by/voided_by)
  #   logged  -> migration_log (a row that was skipped, or loaded but changed/flagged, with a reason)
  class Recorder
    def initialize(sql, tracking, step)
      @sql = sql
      @tracking = tracking
      @step = step
      @id_map = []
      @logs = []
    end

    def mapped(entity, src_row, src_id_column, tgt_id, uuid)
      @id_map << { 'entity' => entity, 'src_id' => src_row[src_id_column], 'tgt_id' => tgt_id, 'uuid' => uuid,
                   'src_creator' => src_row['creator'], 'src_changed_by' => src_row['changed_by'],
                   'src_voided_by' => src_row['voided_by'] }
    end

    # Returns nil, so `filter_map { ... rec.logged(...) }` drops the row.
    def logged(entity, src_id, reason, detail = nil)
      @logs << { 'step' => @step, 'entity' => entity, 'src_id' => src_id, 'reason' => reason,
                 'detail' => detail.nil? ? nil : detail.to_s[0, 1000] }
      nil
    end

    # Writes and clears; returns [id_map rows, log rows].
    def flush
      counts = [@id_map.size, @logs.size]
      @sql.insert(@tracking.table_name('id_map'), @id_map)
      @sql.insert(@tracking.table_name('migration_log'), @logs, ignore: true) # a re-run doesn't log twice
      @id_map = []
      @logs = []
      counts
    end
  end
end
