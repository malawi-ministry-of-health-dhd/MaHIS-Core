# frozen_string_literal: true

module AetcMigration
  # Entry points for the aetc:* rake tasks (lib/tasks/aetc_migration.rake).
  class Cli
    # Runs one task; problems the user can fix are shown without a backtrace.
    def self.run(task, *args)
      new.public_send(task, *args)
    rescue Error => e
      abort "AETC migration: #{e.message}"
    end

    def initialize(config: Config.new, output: $stdout)
      @config = config
      @output = output
    end

    def config
      rows = {
        'MySQL server' => "#{@config.host}:#{@config.port}",
        'MySQL user' => @config.username,
        'Target database' => @config.target_db,
        'AETC source schema' => @config.source_db || '(the schema loaded by aetc:load)',
        'Mappings folder' => @config.mappings_dir.to_s,
        'Batch size' => "#{@config.batch_size} patients",
        'mysql client' => @config.mysql_client
      }
      width = rows.keys.map(&:length).max
      @output.puts 'AETC migration settings'
      rows.each { |label, value| @output.puts "  #{label.ljust(width)}  #{value}" }
    end
  end
end
