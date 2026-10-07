# frozen_string_literal: true

module AetcMigration
  # rake aetc:check: everything that can be verified before migrating, so problems show up now and
  # not halfway through the obs table. Loads the mappings into the tracking schema as a side effect.
  class Preflight
    SOURCE_TABLES = %w[users person person_name person_address person_attribute patient patient_identifier
                       relationship visit encounter obs orders order_extension lab_lims_order_mappings].freeze

    # What AETC uses, and the lookup that maps it: [label, AETC table, AETC column, lookup, extra condition]
    COVERAGE = [
      ['visit types', 'visit', 'visit_type_id', 'lookup_visit_type', nil],
      ['encounter types', 'encounter', 'encounter_type', 'lookup_encounter_type', nil],
      ['order types', 'orders', 'order_type_id', 'lookup_order_type', nil],
      ['identifier types', 'patient_identifier', 'identifier_type', 'lookup_identifier_type', nil],
      ['person attribute types', 'person_attribute', 'person_attribute_type_id', 'lookup_attribute_type', nil],
      ['relationship types', 'relationship', 'relationship', 'lookup_relationship_type', nil],
      ['encounter locations', 'encounter', 'location_id', 'lookup_location', "l.scope = 'clinical'"],
      ['visit locations', 'visit', 'location_id', 'lookup_location', "l.scope = 'default'"],
      ['order specimens', 'orders', 'concept_id', 'lookup_specimen', nil],
      ['obs concepts', 'obs', 'concept_id', 'lookup_concept_question', nil]
    ].freeze

    # Which lookup rows to validate against MaHIS (default: the ones that will be used).
    # Specimens taken from concept.json are already validated as obs concepts and answers.
    TARGET_CONDITIONS = { 'lookup_concept_value' => nil, 'lookup_specimen' => "l.origin = 'order_type.json'" }.freeze

    def initialize(config:, terminal:, schemas:, connection: ActiveRecord::Base.connection)
      @config = config
      @terminal = terminal
      @schemas = schemas
      @db = connection
      @problems = []
    end

    def call
      @terminal.title('AETC migration preflight check')
      check_server
      source = check_source
      tracking = check_tracking(source)
      mappings = check_mappings(tracking)
      check_targets(tracking, mappings) if mappings
      check_coverage(source, tracking) if mappings
      check_fresh_target(source)
      finish(source, tracking)
    end

    private

    def check_server
      @terminal.section('MySQL server')
      version = @db.select_value('SELECT VERSION()')
      @terminal.ok("Connected to #{@config.host}:#{@config.port} as #{@config.username} (MySQL #{version})")
      tables = @db.select_value('SELECT COUNT(*) FROM information_schema.TABLES ' \
                                "WHERE TABLE_SCHEMA = #{@db.quote(@config.target_db)}").to_i
      return problem("Target database #{@config.target_db} has no tables") if tables.zero?

      @terminal.ok("Target database #{@config.target_db} (#{tables} tables)")
    end

    def check_source
      @terminal.section('AETC source')
      source = @schemas.staging_schema
      raise Error, "The AETC source (#{source}) cannot be the target database" if source == @config.target_db

      present = @db.select_values("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = #{@db.quote(source)}")
      missing = SOURCE_TABLES - present
      @terminal.ok("Using #{source}#{@config.source_db ? ' (AETC_SOURCE_DB)' : ''}")
      if missing.any?
        problem("#{source} is missing tables: #{missing.join(', ')}")
      else
        @terminal.ok("All #{SOURCE_TABLES.size} tables the migration reads are present")
      end
      source
    end

    def check_tracking(source)
      tracking = Tracking.for(source, config: @config, schemas: @schemas)
      @terminal.ok("Tracking schema #{tracking.name} is ready")
      tracking
    end

    def check_mappings(tracking)
      @terminal.section('Mappings')
      mappings = Mappings.new(@config.mappings_dir)
      @terminal.info("Folder: #{@config.mappings_dir}")
      missing = mappings.missing_files
      if missing.any?
        problem("Missing mapping files: #{missing.join(', ')}")
        return nil
      end

      loaded = mappings.load_into(tracking, connection: @db)
      @terminal.ok("All #{Mappings::FILES.size} files read; #{@terminal.number(loaded.values.sum)} lookup rows " \
                   "loaded into #{tracking.name}")
      mappings
    rescue Error => e
      problem(e.message)
      nil
    end

    def check_targets(tracking, mappings)
      @terminal.section('MaHIS metadata the mappings point to')
      Mappings::TARGETS.each do |lookup, (table, column, what)|
        used = ['l.target_id IS NOT NULL', TARGET_CONDITIONS.fetch(lookup, "l.action IN ('map', 'review')")].compact.join(' AND ')
        missing = @db.select_values(<<~SQL)
          SELECT DISTINCT l.target_id FROM #{tracking.table_name(lookup)} l
          LEFT JOIN #{target(table)} x ON x.#{column} = l.target_id
          WHERE #{used} AND x.#{column} IS NULL ORDER BY l.target_id
        SQL
        total = @db.select_value("SELECT COUNT(DISTINCT l.target_id) FROM #{tracking.table_name(lookup)} l WHERE #{used}").to_i
        if missing.empty?
          @terminal.ok("#{what.capitalize}: all #{@terminal.number(total)} MaHIS ids exist")
        else
          problem("#{what.capitalize}: #{missing.size} MaHIS #{table} id(s) do not exist: #{sample(missing)}")
        end
      end
      program = mappings.aetc_program_id
      if program && @db.select_value("SELECT COUNT(*) FROM #{target('program')} WHERE program_id = #{program.to_i}").to_i.positive?
        @terminal.ok("AETC program #{program} exists")
      else
        problem("MaHIS program #{program.inspect} (AETC PROGRAM, from encounter_type.json) does not exist")
      end
    end

    def check_coverage(source, tracking)
      @terminal.section('AETC data without a mapping (these rows will be skipped or loaded without the value)')
      COVERAGE.each do |label, table, column, lookup, condition|
        @terminal.detail("Counting #{label} in #{table} (large tables take a moment)") if table == 'obs'
        rows = @db.select_rows(<<~SQL)
          SELECT s.#{column}, COUNT(*) FROM #{qualified(source, table)} s
          LEFT JOIN #{tracking.table_name(lookup)} l ON l.source_id = s.#{column}#{condition ? " AND #{condition}" : ''}
          WHERE s.#{column} IS NOT NULL AND (l.source_id IS NULL OR l.target_id IS NULL)
          GROUP BY s.#{column} ORDER BY COUNT(*) DESC
        SQL
        if rows.empty?
          @terminal.ok("All #{label} used in AETC are mapped")
        else
          count = rows.sum { |_, n| n.to_i }
          @terminal.warn("#{label.capitalize} without a MaHIS mapping: #{rows.size} (#{@terminal.number(count)} " \
                         "#{table} rows): #{sample(rows.map { |id, n| "#{id} (#{@terminal.number(n.to_i)})" })}")
        end
      end
    end

    def check_fresh_target(source)
      @terminal.section('Fresh run')
      overlap = @db.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM (SELECT 1 FROM #{qualified(source, 'encounter')} s
        JOIN #{target('encounter')} t ON t.uuid = s.uuid LIMIT 1) x
      SQL
      if overlap.positive?
        problem("#{@config.target_db} already contains AETC encounters (matching uuids). This tool needs a MaHIS " \
                'database without a previous AETC migration: restore the backup taken before it.')
      else
        @terminal.ok("#{@config.target_db} has no AETC encounters yet")
      end
      persons = @db.select_value("SELECT COUNT(*) FROM #{qualified(source, 'person')} s " \
                                 "JOIN #{target('person')} t ON t.uuid = s.uuid").to_i
      return if persons.zero?

      @terminal.warn("#{@terminal.number(persons)} AETC persons already exist in MaHIS (same uuid); " \
                     'they will be skipped and logged')
    end

    def finish(source, tracking)
      @terminal.section('Result')
      tracking.save_setting('checked_at', Time.current.to_fs(:db))
      if @problems.empty?
        @terminal.ok("Ready to migrate #{source} into #{@config.target_db}")
        return true
      end

      @problems.each { |p| @terminal.error(p) }
      raise Error, "Preflight found #{@problems.size} problem(s). Fix them and run rake aetc:check again."
    end

    def problem(message)
      @problems << message
      @terminal.error(message)
      false
    end

    def sample(values, limit = 10)
      shown = values.first(limit).join(', ')
      values.size > limit ? "#{shown} … (+#{values.size - limit} more)" : shown
    end

    def target(table)
      qualified(@config.target_db, table)
    end

    def qualified(schema, table)
      "#{@db.quote_table_name(schema)}.#{@db.quote_table_name(table)}"
    end
  end
end
