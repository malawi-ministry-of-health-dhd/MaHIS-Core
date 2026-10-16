# frozen_string_literal: true

module AetcMigration
  # Schemas this tool creates on the MySQL server: the AETC staging copy (aetc:load) and the tracking
  # schema of a run. Each one holds a one-row marker table (_aetc_migration) saying what it is;
  # aetc:cleanup only ever offers schemas that have it, and never the target or MySQL's own schemas.
  class Schemas
    MARKER = '_aetc_migration'
    ROLES = %w[staging tracking].freeze

    Entry = Struct.new(:name, :role, :status, :details, :created_at, :updated_at, :size_bytes, :tables,
                       keyword_init: true)

    def initialize(config:, connection: ActiveRecord::Base.connection)
      @config = config
      @db = connection
    end

    def list
      @db.execute('SET SESSION information_schema_stats_expiry = 0') # sizes of freshly loaded tables
      names = @db.select_values(
        "SELECT TABLE_SCHEMA FROM information_schema.TABLES WHERE TABLE_NAME = #{@db.quote(MARKER)}"
      )
      names.reject { |name| protected?(name) }.map { |name| entry(name) }.sort_by { |e| [e.created_at.to_s, e.name] }
    end

    def find(name)
      list.find { |e| e.name == name }
    end

    def exists?(name)
      @db.select_value(
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = #{@db.quote(name)}"
      ).to_i.positive?
    end

    def protected?(name)
      name == @config.target_db || Config::SYSTEM_SCHEMAS.include?(name.to_s.downcase)
    end

    def create!(name, role:, status:, details: {})
      Config.validate_schema_name!(name)
      raise Error, "Unknown schema role #{role.inspect}" unless ROLES.include?(role)
      raise Error, "#{name} is the MaHIS target database or a MySQL system schema" if protected?(name)
      raise Error, "Schema #{name} already exists" if exists?(name)

      @db.execute("CREATE DATABASE #{q(name)} CHARACTER SET utf8mb4")
      @db.execute(<<~SQL)
        CREATE TABLE #{q(name)}.#{q(MARKER)} (
          id TINYINT NOT NULL PRIMARY KEY,
          role VARCHAR(20) NOT NULL,
          status VARCHAR(20) NOT NULL,
          details TEXT NULL,
          created_at DATETIME NOT NULL,
          updated_at DATETIME NOT NULL)
      SQL
      now = @db.quote(Time.current.to_fs(:db))
      @db.execute("INSERT INTO #{q(name)}.#{q(MARKER)} VALUES " \
                  "(1, #{@db.quote(role)}, #{@db.quote(status)}, #{@db.quote(details.to_json)}, #{now}, #{now})")
      find(name)
    end

    def update!(name, status: nil, details: {})
      current = find(name) or raise Error, "#{name} was not created by this tool"
      sets = ["updated_at = #{@db.quote(Time.current.to_fs(:db))}",
              "details = #{@db.quote(current.details.merge(details.stringify_keys).to_json)}"]
      sets << "status = #{@db.quote(status)}" if status
      @db.execute("UPDATE #{q(name)}.#{q(MARKER)} SET #{sets.join(', ')} WHERE id = 1")
    end

    def drop!(name)
      raise Error, "Refusing to drop #{name}: it is the target database or a MySQL system schema" if protected?(name)
      raise Error, "Refusing to drop #{name}: it was not created by this tool" unless find(name)

      @db.execute("DROP DATABASE #{q(name)}")
    end

    # aetc_YYYYMMDD, or aetc_YYYYMMDD_2, _3 ... when that name is taken.
    def next_staging_name(date = Date.current)
      base = "aetc_#{date.strftime('%Y%m%d')}"
      return base unless exists?(base)

      (2..).each { |n| return "#{base}_#{n}" unless exists?("#{base}_#{n}") }
    end

    # The AETC schema to migrate from: AETC_SOURCE_DB, else the only staging schema loaded by aetc:load.
    def staging_schema
      if (name = @config.source_db)
        raise Error, "AETC_SOURCE_DB=#{name} does not exist on the MySQL server" unless exists?(name)

        return name
      end
      loaded = list.select { |e| e.role == 'staging' && e.status == 'loaded' }
      case loaded.size
      when 0
        raise Error, 'No AETC schema is loaded yet. Run rake "aetc:load[/path/to/aetc_dump.sql]", or, if AETC is ' \
                     'already restored on this MySQL server, set AETC_SOURCE_DB=<schema name>'
      when 1 then loaded.first.name
      else
        raise Error, "More than one AETC schema is loaded (#{loaded.map(&:name).join(', ')}). " \
                     'Choose one with AETC_SOURCE_DB=<name>.'
      end
    end

    private

    def entry(name)
      marker = @db.select_one("SELECT role, status, details, created_at, updated_at FROM #{q(name)}.#{q(MARKER)} " \
                              'WHERE id = 1') || {}
      stats = @db.select_one(
        'SELECT COUNT(*) AS tables, COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0) AS size_bytes ' \
        "FROM information_schema.TABLES WHERE TABLE_SCHEMA = #{@db.quote(name)}"
      )
      Entry.new(name: name, role: marker['role'], status: marker['status'], details: parse(marker['details']),
                created_at: marker['created_at'], updated_at: marker['updated_at'],
                size_bytes: stats['size_bytes'].to_i, tables: stats['tables'].to_i)
    end

    def parse(json)
      json.present? ? JSON.parse(json) : {}
    rescue JSON::ParserError
      {}
    end

    def q(name)
      @db.quote_table_name(name)
    end
  end
end
