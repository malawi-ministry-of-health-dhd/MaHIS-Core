# frozen_string_literal: true

module AetcMigration
  # Settings for the AETC -> MaHIS-core migration.
  #
  # The MySQL server and the target database come from config/database.yml (the current Rails env).
  # Everything else can be overridden with environment variables:
  #   AETC_SOURCE_DB      AETC staging schema to migrate from (default: the one loaded by aetc:load)
  #   AETC_MAPPINGS_DIR   folder with the mapping files (default: db/aetc_migration/mappings)
  #   AETC_BATCH_SIZE     rows (or, for clinical steps, patients) per batch/transaction (default: 500)
  #   MYSQL_CLIENT        mysql command-line client used by aetc:load (default: mysql)
  #   AETC_CREATOR_USER_ID  MaHIS user recorded as creator of the aetc_migration user (default: 1)
  class Config
    SCHEMA_NAME = /\A[A-Za-z0-9_]+\z/
    SYSTEM_SCHEMAS = %w[mysql sys information_schema performance_schema].freeze
    DEFAULT_BATCH_SIZE = 500

    attr_reader :root

    def initialize(env: ENV, db_config: nil, root: nil)
      @env = env
      @db_config = (db_config || ActiveRecord::Base.connection_db_config.configuration_hash).symbolize_keys
      @root = Pathname(root || Rails.root)
    end

    def target_db
      @db_config.fetch(:database).to_s
    end

    def host
      (@db_config[:host].presence || 'localhost').to_s
    end

    def port
      (@db_config[:port].presence || 3306).to_i
    end

    def socket
      @db_config[:socket].presence
    end

    def username
      @db_config[:username].to_s
    end

    def password
      @db_config[:password].to_s
    end

    def source_db
      name = @env['AETC_SOURCE_DB'].presence
      name && self.class.validate_schema_name!(name)
    end

    def mappings_dir
      Pathname(@env['AETC_MAPPINGS_DIR'].presence || root.join('db', 'aetc_migration', 'mappings'))
    end

    def log_dir
      root.join('log')
    end

    def batch_size
      value = @env['AETC_BATCH_SIZE'].presence
      return DEFAULT_BATCH_SIZE unless value

      Integer(value).tap { |n| raise Error, 'AETC_BATCH_SIZE must be greater than 0' unless n.positive? }
    rescue ArgumentError
      raise Error, "AETC_BATCH_SIZE must be a number, got #{value.inspect}"
    end

    # True when AETC_BATCH_SIZE is set; the clinical steps then use it instead of their own default
    # (visits 1,000, encounters/orders 500, obs 100 patients per batch).
    def batch_size_set?
      @env['AETC_BATCH_SIZE'].present?
    end

    def creator_user_id
      Integer(@env['AETC_CREATOR_USER_ID'].presence || 1)
    rescue ArgumentError
      raise Error, "AETC_CREATOR_USER_ID must be a number, got #{@env['AETC_CREATOR_USER_ID'].inspect}"
    end

    def mysql_client
      @env['MYSQL_CLIENT'].presence || 'mysql'
    end

    # Tracking schema (id_map, migration_log, ...) that belongs to a staging schema.
    def tracking_db_for(source_db)
      self.class.validate_schema_name!("#{source_db}_migration")
    end

    def self.validate_schema_name!(name)
      return name if name.to_s.match?(SCHEMA_NAME)

      raise Error, "Invalid schema name #{name.inspect}: use letters, digits and underscores only"
    end
  end
end
