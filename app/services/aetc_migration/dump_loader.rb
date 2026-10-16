# frozen_string_literal: true

require 'open3'
require 'tempfile'
require 'zlib'

module AetcMigration
  # Loads an AETC mysqldump file (.sql or .sql.gz) into a new staging schema (aetc_YYYYMMDD) on the
  # MaHIS MySQL server, by streaming it into the mysql command-line client.
  #
  # While streaming it drops statements that would break the load or send data elsewhere:
  #   SET @@GLOBAL.GTID_PURGED  (fails on a server with its own GTIDs)
  #   USE / CREATE DATABASE      (would load into another database)
  class DumpLoader
    KEY_TABLES = %w[person patient visit encounter obs orders].freeze
    SKIPPED_STATEMENTS = {
      /\ASET @@GLOBAL\.GTID_PURGED/i => 'SET @@GLOBAL.GTID_PURGED',
      /\AUSE\s/i => 'USE',
      /\ACREATE DATABASE/i => 'CREATE DATABASE'
    }.freeze

    def initialize(config:, terminal:, schemas:, connection: ActiveRecord::Base.connection)
      @config = config
      @terminal = terminal
      @schemas = schemas
      @db = connection
    end

    def call(path, name: nil)
      path = Pathname(File.expand_path(path.to_s))
      check_file!(path)
      client = check_client!
      name = name.presence || @schemas.next_staging_name
      Config.validate_schema_name!(name)
      raise Error, "Schema #{name} already exists; choose another name or run rake aetc:cleanup" if @schemas.exists?(name)

      @terminal.title("Load AETC dump into #{name}")
      @terminal.summary('Dump file' => path.to_s, 'Size' => @terminal.number_to_size(path.size),
                        'MySQL server' => "#{@config.host}:#{@config.port}", 'mysql client' => client)
      @schemas.create!(name, role: 'staging', status: 'loading',
                             details: { 'dump' => path.to_s, 'dump_bytes' => path.size })
      created = true
      @terminal.ok("Created schema #{name}")

      skipped = stream(path, name)
      @schemas.update!(name, status: 'loaded', details: { 'loaded_at' => Time.current.to_fs(:db) })
      report(name, skipped)
      name
    rescue StandardError, Interrupt => e
      if created
        @schemas.update!(name, status: 'failed', details: { 'error' => e.message.to_s.truncate(500) })
        @terminal.warn("#{name} is marked as failed; rake aetc:cleanup removes it")
      end
      raise
    end

    private

    def check_file!(path)
      raise Error, "Dump file not found: #{path}" unless path.file?
      raise Error, "Dump file is empty: #{path}" if path.size.zero?
    end

    def check_client!
      out, status = Open3.capture2e(@config.mysql_client, '--version')
      raise Error, "#{@config.mysql_client} --version failed: #{out.strip}" unless status.success?

      out.strip
    rescue Errno::ENOENT
      raise Error, "The mysql command-line client (#{@config.mysql_client}) was not found. Install it or set MYSQL_CLIENT."
    end

    # Streams the dump into `mysql <name>` and returns {statement => count} of what was left out.
    def stream(path, name)
      skipped = Hash.new(0)
      with_options_file do |options_file|
        cmd = [@config.mysql_client, "--defaults-extra-file=#{options_file}", '--default-character-set=utf8mb4',
               '--max-allowed-packet=1G', name]
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait|
          errors = Thread.new { stderr.read }
          Thread.new { stdout.read }
          begin
            @terminal.progress('Loading dump', total: path.size, bytes: true) do |bar|
              each_statement_line(path, bar) do |line, statement, first_line|
                if statement
                  skipped[statement] += 1 if first_line
                else
                  stdin.write(line)
                end
              end
            end
          rescue Errno::EPIPE
            # mysql stopped reading: its error is reported below
          ensure
            stdin.close unless stdin.closed?
          end
          status = wait.value
          message = errors.value.to_s.lines.reject { |l| l.include?('Using a password') }.join.strip
          raise Error, "mysql stopped with an error: #{message.presence || status}" unless status.success?
        end
      end
      skipped
    end

    # Yields each line of the dump with the name of the skipped statement it belongs to (or nil) and
    # whether it is that statement's first line; advances the progress bar by the bytes read from disk.
    def each_statement_line(path, bar)
      File.open(path, 'rb') do |file|
        reader = path.extname == '.gz' ? Zlib::GzipReader.new(file) : file
        position = 0
        skipping = nil
        reader.each_line do |line|
          first_line = skipping.nil?
          skipping ||= SKIPPED_STATEMENTS.find { |pattern, _| line.match?(pattern) }&.last
          yield line, skipping, first_line
          skipping = nil if skipping && line.rstrip.end_with?(';')
          read = file.pos
          bar.advance(read - position) if read > position
          position = read
        end
      end
    rescue Zlib::GzipFile::Error => e
      raise Error, "#{path} is not a valid .gz file: #{e.message}"
    end

    # The password goes in a private temporary options file instead of the command line.
    def with_options_file
      file = Tempfile.new(['aetc-mysql', '.cnf'])
      File.chmod(0o600, file.path)
      lines = ['[client]', "host=#{@config.host}", "port=#{@config.port}", "user=#{@config.username}"]
      lines << "password=\"#{@config.password.gsub(/["\\]/) { |c| "\\#{c}" }}\"" if @config.password.present?
      lines << "socket=#{@config.socket}" if @config.socket
      file.write("#{lines.join("\n")}\n")
      file.close
      yield file.path
    ensure
      file&.close!
    end

    def report(name, skipped)
      skipped.each { |statement, count| @terminal.warn("Left out #{count} #{statement} statement(s) from the dump") }
      present = @db.select_values("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = #{@db.quote(name)}")
      (KEY_TABLES & present).each { |t| @db.execute("ANALYZE TABLE #{@db.quote_table_name(name)}.#{@db.quote_table_name(t)}") }
      @db.execute('SET SESSION information_schema_stats_expiry = 0')
      tables = @db.select_rows(
        'SELECT TABLE_NAME, TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH FROM information_schema.TABLES ' \
        "WHERE TABLE_SCHEMA = #{@db.quote(name)} AND TABLE_NAME <> #{@db.quote(Schemas::MARKER)}"
      )
      raise Error, "The dump created no tables in #{name}" if tables.empty?

      missing = KEY_TABLES - tables.map(&:first)
      @terminal.warn("Tables not found in the dump: #{missing.join(', ')}") if missing.any?
      @schemas.update!(name, details: { 'tables' => tables.size })
      @terminal.section('Loaded')
      key = tables.select { |t, _, _| KEY_TABLES.include?(t) }.sort_by { |t, _, _| KEY_TABLES.index(t) }
      @terminal.table(['Table', 'Rows (approx.)', 'Size'],
                      key.map { |t, rows, bytes| [t, rows.to_i, @terminal.number_to_size(bytes.to_i)] })
      @terminal.ok("#{tables.size} tables, #{@terminal.number_to_size(tables.sum { |_, _, b| b.to_i })} in #{name}")
      @terminal.detail("Next: rake aetc:check   (uses #{name}; set AETC_SOURCE_DB if you load more than one)")
    end
  end
end
