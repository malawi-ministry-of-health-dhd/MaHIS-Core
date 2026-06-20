# frozen_string_literal: true

require 'open3'
require 'zlib'

class DatabaseSqlImporter
  class ImportError < StandardError; end

  MYSQL_CLIENT_CANDIDATES = [
    '/opt/homebrew/opt/mysql-client@8.4/bin/mysql',
    '/usr/local/opt/mysql-client@8.4/bin/mysql',
    'mysql'
  ].freeze
  ROUTINE_BLOCK_START = /^-- Dumping routines for database /
  ROUTINE_BLOCK_END = /^-- Final view structure for view /
  VALID_SQL_MODE = /\A[A-Z0-9_,]*\z/

  attr_reader :config, :file_path, :skip_routines, :stderr_text

  def initialize(config:, file_path:, skip_routines: false, continue_on_error: false, mysql_client: nil)
    @config = config.to_h.transform_keys(&:to_s)
    @file_path = file_path.to_s
    @skip_routines = skip_routines
    @continue_on_error = continue_on_error
    @mysql_client = mysql_client || ENV['MYSQL_CLIENT'] || default_mysql_client
  end

  def import!
    raise ImportError, "SQL file not found: #{file_path}" unless File.file?(file_path)

    stdout_text = nil
    @stderr_text = nil
    status = nil
    write_error = nil

    Open3.popen3(mysql_environment, *mysql_command) do |stdin, stdout, stderr, wait_thread|
      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }

      begin
        write_sql(stdin)
      rescue Errno::EPIPE, IOError => e
        write_error = e
      ensure
        stdin.close unless stdin.closed?
      end

      stdout_text = stdout_reader.value
      @stderr_text = stderr_reader.value
      status = wait_thread.value
    end

    return true if status.success? && write_error.nil?

    detail = [stderr_text, stdout_text, write_error&.message].compact.join("\n").strip
    detail = detail[-4_000, 4_000] if detail.length > 4_000
    raise ImportError, "Import failed for #{File.basename(file_path)} (exit #{status.exitstatus}): #{detail}"
  rescue Errno::ENOENT => e
    raise ImportError, "MySQL client #{@mysql_client.inspect} was not found: #{e.message}"
  end

  def mysql_command
    command = [@mysql_client, '--protocol=TCP']
    command += ['--host', config.fetch('host')] if present?(config['host'])
    command += ['--port', config.fetch('port').to_s] if present?(config['port'])
    command += ['--user', config.fetch('username').to_s] if present?(config['username'])
    command += ["--connect-timeout=#{config.fetch('connect_timeout', 10)}"]
    command += ssl_arguments
    command << '--force' if @continue_on_error
    command << config.fetch('database').to_s
    command
  end

  def mysql_environment
    return {} unless present?(config['password'])

    { 'MYSQL_PWD' => config.fetch('password').to_s }
  end

  private

  def default_mysql_client
    MYSQL_CLIENT_CANDIDATES.find do |candidate|
      !candidate.include?(File::SEPARATOR) || File.executable?(candidate)
    end
  end

  def write_sql(output)
    output.write("SET SESSION sql_mode = '#{sql_mode}';\n") if sql_mode

    skipping = false
    each_source_line do |line|
      if skip_routines && line.match?(ROUTINE_BLOCK_START)
        skipping = true
        next
      end

      if skipping && line.match?(ROUTINE_BLOCK_END)
        skipping = false
      end

      output.write(sanitize_line(line)) unless skipping
    end
  end

  def each_source_line(&block)
    if File.extname(file_path) == '.gz'
      Zlib::GzipReader.open(file_path) { |input| input.each_line(&block) }
    else
      File.foreach(file_path, &block)
    end
  end

  def sql_mode
    variables = config.fetch('variables', {}).to_h.transform_keys(&:to_s)
    mode = variables['sql_mode'] || ENV['DB_SQL_MODE']
    return if mode.nil?

    normalized = mode.to_s.upcase
    raise ImportError, "Unsafe sql_mode value: #{mode.inspect}" unless normalized.match?(VALID_SQL_MODE)

    normalized
  end

  def ssl_arguments
    mode = config['ssl_mode'] || config['sslmode']
    arguments = []
    arguments << "--ssl-mode=#{mode.to_s.upcase}" if present?(mode)
    arguments << "--ssl-ca=#{config['sslca']}" if present?(config['sslca'])
    arguments << "--ssl-cert=#{config['sslcert']}" if present?(config['sslcert'])
    arguments << "--ssl-key=#{config['sslkey']}" if present?(config['sslkey'])
    arguments
  end

  def sanitize_line(line)
    return line unless skip_routines

    line.gsub(/\bDEFINER\s*=\s*`[^`]+`@`[^`]+`\s*/i, '')
  end

  def present?(value)
    !value.nil? && !value.to_s.empty?
  end
end
