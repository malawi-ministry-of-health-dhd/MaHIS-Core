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
  end
end
