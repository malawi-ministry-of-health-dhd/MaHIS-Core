# frozen_string_literal: true

module AetcMigration
  module Steps
    # Base for the clinical steps (visits, encounters, orders, obs). They work on batches of AETC
    # patients that the previous step has already covered, and move rows with set-based SQL:
    # INSERT ... SELECT joining the AETC table to id_map and the lookup_* tables, with the skipped
    # rows logged by matching INSERT ... SELECT statements, and id_map filled by joining on uuid.
    class PatientBatched < Base
      PATIENTS_PER_BATCH = 500

      # The step whose checkpoint this step may not overtake.
      def self.after
        raise NotImplementedError
      end

      def waiting_for
        "the #{self.class.after} step" if checkpoint(self.class.after).zero?
      end

      private

      # Yields (patient ids, recorder) per batch, each in its own transaction with the checkpoint.
      def each_patient_batch
        upto = [checkpoint(self.class.after), run.cap].compact.min
        last = checkpoint
        patients = "FROM #{trk('id_map')} WHERE entity = 'patient' AND src_id > %d AND src_id <= #{upto.to_i}"
        total = sql.value("SELECT COUNT(*) #{format(patients, last)}").to_i
        terminal.progress("#{title} (patients)", total: total) do |bar|
          loop do
            ids = sql.values("SELECT src_id #{format(patients, last)} ORDER BY src_id LIMIT #{patients_per_batch}")
            break if ids.empty?

            recorder = Recorder.new(sql, run.tracking, key)
            sql.db.transaction do
              yield ids, recorder
              recorder.flush
              last = ids.last
              run.tracking.save_checkpoint(key, last)
            end
            bar.advance(ids.size)
          end
        end
      end

      def patients_per_batch
        run.config.batch_size_set? ? run.config.batch_size : self.class::PATIENTS_PER_BATCH
      end

      # SQL: the row's owner (AETC patient/person) is voided, so its voided rows come along.
      def owner_voided(person_column)
        "(EXISTS (SELECT 1 FROM #{src('patient')} ov_p WHERE ov_p.patient_id = #{person_column} AND ov_p.voided = 1) " \
          "OR EXISTS (SELECT 1 FROM #{src('person')} ov_s WHERE ov_s.person_id = #{person_column} AND ov_s.voided = 1))"
      end

      # SQL: a date column, NULL when it is empty or a zero date.
      def dt(column)
        "IF(#{column} >= '1000-01-01', #{column}, NULL)"
      end

      # SQL: a date column, 1900-01-01 when it is empty or a zero date (for NOT NULL columns).
      def dt_required(column)
        "IF(#{column} >= '1000-01-01', #{column}, '1900-01-01 00:00:00')"
      end

      def not_mapped(entity, id_column)
        "NOT EXISTS (SELECT 1 FROM #{trk('id_map')} nm WHERE nm.entity = '#{entity}' AND nm.src_id = #{id_column})"
      end

      # Inserts migration_log rows from a SELECT returning (entity, src_id, reason, detail).
      def log_rows(select)
        sql.write("INSERT IGNORE INTO #{trk('migration_log')} (step, entity, src_id, reason, detail) " \
                  "SELECT #{sql.quote(key)}, x.* FROM (#{select}) x")
      end

      # Records id_map rows for the AETC rows of `table` now present in MaHIS with the same uuid.
      def map_by_uuid(entity, table, id_column, target_table, target_id_column, where)
        sql.write(<<~SQL)
          INSERT INTO #{trk('id_map')} (entity, src_id, tgt_id, uuid, src_creator, src_changed_by, src_voided_by)
          SELECT '#{entity}', s.#{id_column}, t.#{target_id_column}, s.uuid, s.creator, #{changed_by_column(table)}, s.voided_by
          FROM #{src(table)} s JOIN #{tgt(target_table)} t ON #{sql.same_text(run.target, target_table, 'uuid', 't', 's')}
          WHERE #{where} AND #{not_mapped(entity, "s.#{id_column}")}
        SQL
      end

      def changed_by_column(table)
        table == 'obs' || table == 'orders' ? 'NULL' : 's.changed_by'
      end
    end
  end
end
