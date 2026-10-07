# frozen_string_literal: true

module AetcMigration
  module Steps
    # A migration step: reads AETC rows in batches (ordered by id, after the step's checkpoint),
    # writes MaHIS rows, and records id_map / migration_log rows. Each batch is one transaction
    # that also saves the checkpoint, so a stopped run continues where it left off.
    class Base
      EPOCH = Time.new(1900, 1, 1) # for NOT NULL dates that are empty (or zero) in AETC

      def self.key
        name.demodulize.underscore
      end

      attr_reader :counts

      def initialize(run)
        @run = run
        @counts = Hash.new(0)
      end

      def key
        self.class.key
      end

      def title
        key.humanize
      end

      # Returns a reason (string) when the step can't run yet in this run, else nil.
      def waiting_for; end

      private

      attr_reader :run

      def sql
        run.sql
      end

      def terminal
        run.terminal
      end

      def src(table)
        run.src(table)
      end

      def tgt(table)
        run.tgt(table)
      end

      def trk(table)
        run.trk(table)
      end

      def checkpoint(step = key)
        run.tracking.checkpoint(step)
      end

      # Yields (rows, recorder) for each batch of AETC rows with id_column in (checkpoint, upto].
      def each_batch(table, id_column, upto: nil, where: nil, label: title)
        last = checkpoint
        range = ["#{id_column} > #{last.to_i}"]
        range << "#{id_column} <= #{upto.to_i}" if upto
        range << where if where
        total = sql.value("SELECT COUNT(*) FROM #{src(table)} WHERE #{range.join(' AND ')}").to_i
        terminal.progress(label, total: total) do |bar|
          loop do
            conditions = ["#{id_column} > #{last.to_i}", *range.drop(1)].join(' AND ')
            rows = sql.select("SELECT * FROM #{src(table)} WHERE #{conditions} ORDER BY #{id_column} " \
                              "LIMIT #{run.config.batch_size}")
            break if rows.empty?

            recorder = Recorder.new(sql, run.tracking, key)
            sql.db.transaction do
              yield rows, recorder
              recorder.flush
              last = rows.last[id_column]
              run.tracking.save_checkpoint(key, last)
            end
            bar.advance(rows.size)
          end
        end
      end

      # {AETC id => MaHIS id} from id_map.
      def mapped_ids(entity, src_ids)
        src_ids = Array(src_ids).compact.uniq
        return {} if src_ids.empty?

        sql.select("SELECT src_id, tgt_id FROM #{trk('id_map')} WHERE entity = #{sql.quote(entity)} " \
                   "AND src_id IN (#{sql.list(src_ids)})").to_h { |r| [r['src_id'], r['tgt_id']] }
      end

      # AETC creator/voided_by -> migration user; dates kept.
      def audit(src)
        voided = truthy?(src['voided'])
        {
          'creator' => run.migration_user_id,
          'date_created' => src['date_created'] || EPOCH,
          'voided' => voided ? 1 : 0,
          'voided_by' => voided || !src['voided_by'].nil? ? run.migration_user_id : nil,
          'date_voided' => src['date_voided'],
          'void_reason' => src['void_reason']
        }
      end

      def changed(src)
        { 'changed_by' => src['changed_by'].nil? ? nil : run.migration_user_id, 'date_changed' => src['date_changed'] }
      end

      def truthy?(value)
        value.present? && value != 0 && value != '0' && value != false
      end

      # AETC ids (from ids) whose person or patient row is voided: they bring their voided rows too.
      def voided_owners(ids)
        ids = Array(ids).compact.uniq
        return Set.new if ids.empty?

        sql.values("SELECT person_id FROM #{src('person')} WHERE voided = 1 AND person_id IN (#{sql.list(ids)}) " \
                   "UNION SELECT patient_id FROM #{src('patient')} WHERE voided = 1 AND patient_id IN (#{sql.list(ids)})")
           .to_set
      end

      def count(table, rows)
        @counts[table] += rows
      end
    end
  end
end
