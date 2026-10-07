# frozen_string_literal: true

module AetcMigration
  # rake aetc:migrate: runs the steps in dependency order. Each batch is committed on its own, so a
  # stopped run continues from the checkpoints. DRY_RUN runs everything in one transaction and rolls it
  # back; LIMIT=n migrates only the next n AETC persons (and what belongs to them).
  class Runner
    STEPS = [Steps::Users, Steps::Persons].freeze
    DRY_RUN_DEFAULT_LIMIT = 1000

    def initialize(config:, terminal:, schemas:, dry_run: false, limit: nil, sql: Sql.new)
      @config = config
      @terminal = terminal
      @schemas = schemas
      @dry_run = dry_run
      @limit = limit
      @sql = sql
    end

    def call(only = nil)
      steps = select_steps(only)
      run = prepare
      header(run, steps)
      started = @terminal.monotonic
      results = @dry_run ? dry_run(steps, run) : steps.map { |klass| execute(klass, run) }
      summary(results, @terminal.monotonic - started)
    rescue Interrupt
      @terminal.warn('Stopped. Finished batches are saved; run the same command again to continue.') unless @dry_run
      raise Error, 'Interrupted'
    end

    private

    def select_steps(only)
      return STEPS if only.blank?

      step = STEPS.find { |s| s.key == only.to_s }
      raise Error, "Unknown step #{only.inspect}. Steps: #{STEPS.map(&:key).join(', ')}" unless step

      [step]
    end

    def prepare
      source = @schemas.staging_schema
      tracking = Tracking.for(source, config: @config, schemas: @schemas)
      if tracking.setting('check_passed_at').blank?
        raise Error, "rake aetc:check has not passed for #{source} yet. Run it and fix what it reports first."
      end

      mappings = Mappings.new(@config.mappings_dir)
      mappings.load_into(tracking, connection: @sql.db) # pick up any edits to the mapping files
      RunContext.new(config: @config, terminal: @terminal, sql: @sql, source: source, tracking: tracking,
                     mappings: mappings, dry_run: @dry_run, cap: person_cap(source, tracking))
    end

    # Highest AETC person_id covered by LIMIT (counted from where the persons step stopped).
    def person_cap(source, tracking)
      limit = @limit || (DRY_RUN_DEFAULT_LIMIT if @dry_run)
      return nil unless limit

      @sql.value("SELECT person_id FROM #{@sql.name(source, 'person')} WHERE person_id > #{tracking.checkpoint('persons')} " \
                 "ORDER BY person_id LIMIT 1 OFFSET #{limit.to_i - 1}")&.to_i
    end

    def header(run, steps)
      @terminal.title("Migrate #{run.source} → #{run.target}")
      limit = @limit || (DRY_RUN_DEFAULT_LIMIT if @dry_run)
      @terminal.summary(
        'Mode' => @dry_run ? 'DRY RUN: everything is rolled back at the end' : 'live (each batch is committed)',
        'Persons' => limit ? "next #{@terminal.number(limit)} AETC persons#{run.cap ? " (up to person_id #{run.cap})" : ' (all remaining)'}" : 'all',
        'Steps' => steps.map(&:key).join(' → '),
        'Batch size' => "#{@config.batch_size} rows",
        'Tracking' => run.tracking.name,
        'Log file' => @terminal.log_path.to_s
      )
      @terminal.warn('Back up MaHIS first: mysqldump … > mahis_before_aetc.sql') unless @dry_run
    end

    def dry_run(steps, run)
      results = nil
      @sql.db.transaction do
        results = steps.map { |klass| execute(klass, run) }
        raise ActiveRecord::Rollback
      end
      @terminal.warn('Dry run: every change above was rolled back')
      results
    end

    def execute(klass, run)
      step = klass.new(run)
      @terminal.section("#{STEPS.index(klass) + 1}/#{STEPS.size}  #{step.title}")
      if (reason = step.waiting_for)
        @terminal.warn("Skipped: waiting for #{reason}")
        return [step, :waiting, 0]
      end

      started = @terminal.monotonic
      counts = step.call
      elapsed = @terminal.monotonic - started
      show_counts(step, counts, run)
      [step, :done, elapsed]
    end

    def show_counts(step, counts, run)
      @terminal.table(%w[Table Inserted], counts.map { |table, n| [table, n] }) if counts.any?
      reasons = @sql.select("SELECT entity, reason, COUNT(*) AS n FROM #{run.trk('migration_log')} " \
                            "WHERE step = #{@sql.quote(step.key)} GROUP BY entity, reason ORDER BY entity, n DESC")
      return if reasons.empty?

      @terminal.info('Logged (skipped, or loaded and flagged) so far in this step:')
      @terminal.table(%w[Entity Reason Rows], reasons.map { |r| [r['entity'], r['reason'], r['n'].to_i] })
    end

    def summary(results, elapsed)
      @terminal.section('Summary')
      @terminal.table(%w[Step Result Inserted Time],
                      results.map do |step, state, seconds|
                        [step.key, state == :done ? 'done' : 'waiting', step.counts.values.sum,
                         state == :done ? @terminal.duration(seconds) : '-']
                      end)
      @terminal.ok("Finished in #{@terminal.duration(elapsed)}#{' (dry run, rolled back)' if @dry_run}")
      @terminal.detail('Next: rake aetc:migrate again to continue, or rake aetc:schemas / aetc:cleanup')
    end
  end
end
