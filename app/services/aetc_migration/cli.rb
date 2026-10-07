# frozen_string_literal: true

module AetcMigration
  # Entry points for the aetc:* rake tasks (lib/tasks/aetc_migration.rake).
  class Cli
    # Runs one task; problems the user can fix are shown without a backtrace.
    def self.run(task, *args)
      cli = new
      cli.public_send(task, *args)
    rescue Error => e
      abort "AETC migration stopped: #{e.message}" unless cli

      cli.terminal.error(e.message)
      cli.terminal.detail("Log file: #{cli.terminal.log_path}") if cli.terminal.log_path
      exit 1
    ensure
      cli&.terminal&.close
    end

    attr_reader :terminal

    def initialize(config: Config.new, terminal: nil)
      @config = config
      @terminal = terminal || Terminal.new(log_dir: config.log_dir)
    end

    def config
      terminal.title('AETC migration settings')
      terminal.summary(
        'MySQL server' => "#{@config.host}:#{@config.port}",
        'MySQL user' => @config.username,
        'Target database' => @config.target_db,
        'AETC source schema' => @config.source_db || '(the schema loaded by aetc:load)',
        'Mappings folder' => @config.mappings_dir.to_s,
        'Batch size' => "#{@config.batch_size} patients",
        'mysql client' => @config.mysql_client,
        'Log file' => terminal.log_path.to_s
      )
    end

    def load_dump(path = nil, name = nil)
      raise Error, 'Give the dump file: rake "aetc:load[/path/to/aetc_dump.sql]"' if path.blank?

      DumpLoader.new(config: @config, terminal: terminal, schemas: Schemas.new(config: @config)).call(path, name: name)
    end

    def check
      Preflight.new(config: @config, terminal: terminal, schemas: Schemas.new(config: @config)).call
    end

    # DRY_RUN=1 and LIMIT=n come from the environment.
    def migrate(step = nil)
      Runner.new(config: @config, terminal: terminal, schemas: Schemas.new(config: @config),
                 dry_run: ENV['DRY_RUN'].present? && ENV['DRY_RUN'] != '0', limit: limit).call(step)
    end

    def cleanup(only = nil)
      Cleanup.new(config: @config, terminal: terminal, schemas: Schemas.new(config: @config)).call(only: only)
    end

    def schemas
      terminal.title('Schemas created by the AETC migration tool')
      entries = Schemas.new(config: @config).list
      return terminal.info('None. rake "aetc:load[/path/to/dump.sql]" creates the first one.') if entries.empty?

      terminal.table(%w[Schema Role Status Created Size Tables],
                     entries.map do |e|
                       [e.name, e.role, e.status, e.created_at&.strftime('%Y-%m-%d %H:%M'),
                        terminal.number_to_size(e.size_bytes), e.tables]
                     end)
    end

    private

    def limit
      return nil if ENV['LIMIT'].blank?

      Integer(ENV['LIMIT']).tap { |n| raise Error, 'LIMIT must be greater than 0' unless n.positive? }
    rescue ArgumentError
      raise Error, "LIMIT must be a number, got #{ENV['LIMIT'].inspect}"
    end
  end
end
