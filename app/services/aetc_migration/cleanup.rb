# frozen_string_literal: true

require 'csv'

module AetcMigration
  # rake aetc:cleanup: drops the schemas this tool created, one at a time, each only after the exact
  # schema name is typed. A tracking schema's id_map and migration_log are first exported to CSV under
  # log/aetc_migration/, so the record of what was migrated survives. The target database and schemas
  # the tool did not create are never offered.
  class Cleanup
    EXPORT_TABLES = %w[id_map migration_log].freeze

    def initialize(config:, terminal:, schemas:, connection: ActiveRecord::Base.connection)
      @config = config
      @terminal = terminal
      @schemas = schemas
      @db = connection
    end

    def call(only: nil)
      @terminal.title('Clean up AETC migration schemas')
      entries = select_entries(only)
      return @terminal.info('Nothing to clean up: no schemas created by this tool.') if entries.empty?

      @terminal.table(%w[Schema Role Status Size Tables],
                      entries.map { |e| [e.name, e.role, e.status, @terminal.number_to_size(e.size_bytes), e.tables] })
      @terminal.warn('Dropping a schema cannot be undone.')
      @terminal.detail("The MaHIS database (#{@config.target_db}) is never touched.")

      dropped = entries.sort_by { |e| e.role == 'tracking' ? 0 : 1 }.count { |entry| handle(entry) }
      @terminal.section('Done')
      @terminal.ok("Dropped #{dropped} of #{entries.size} schema(s)")
    end

    private

    def select_entries(only)
      entries = @schemas.list
      return entries if only.blank?

      Config.validate_schema_name!(only)
      found = entries.select { |e| e.name == only }
      raise Error, "#{only} is not a schema created by this tool (see rake aetc:schemas)" if found.empty?

      found
    end

    # Returns true when the schema was dropped.
    def handle(entry)
      @terminal.section("#{entry.name}  (#{entry.role}, #{entry.status}, #{@terminal.number_to_size(entry.size_bytes)})")
      answer = @terminal.ask("Type #{entry.name} to drop it, or press Enter to keep it:")
      unless answer == entry.name
        answer.present? ? @terminal.warn("That did not match; kept #{entry.name}") : @terminal.info("Kept #{entry.name}")
        return false
      end

      export(entry.name) if entry.role == 'tracking'
      @schemas.drop!(entry.name)
      @terminal.ok("Dropped #{entry.name}")
      true
    end

    def export(schema)
      present = @db.select_values("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = #{@db.quote(schema)}")
      tables = EXPORT_TABLES & present
      return if tables.empty?

      dir = @config.log_dir.join('aetc_migration', "#{schema}-#{Time.current.strftime('%Y%m%d-%H%M%S')}")
      FileUtils.mkdir_p(dir)
      tables.each { |table| export_table(schema, table, dir.join("#{table}.csv")) }
      @terminal.ok("Exported #{tables.join(' and ')} to #{dir}")
    rescue SystemCallError, IOError, ActiveRecord::StatementInvalid, Mysql2::Error => e
      raise Error, "Could not export #{schema} (nothing was dropped): #{e.message}"
    end

    def export_table(schema, table, path)
      name = "#{@db.quote_table_name(schema)}.#{@db.quote_table_name(table)}"
      total = @db.select_value("SELECT COUNT(*) FROM #{name}").to_i
      @terminal.progress("Exporting #{table}", total: total) do |bar|
        result = @db.raw_connection.query("SELECT * FROM #{name}", stream: true, cache_rows: false, as: :array)
        CSV.open(path, 'w') do |csv|
          csv << result.fields
          result.each do |row|
            csv << row.map { |v| v.respond_to?(:strftime) ? v.strftime('%Y-%m-%d %H:%M:%S') : v }
            bar.advance
          end
        end
      end
    end
  end
end
