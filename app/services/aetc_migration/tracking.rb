# frozen_string_literal: true

module AetcMigration
  # The tracking schema of a run (<staging>_migration): which AETC row became which MaHIS row (id_map),
  # every skipped or changed row with a reason (migration_log), how far each step got (checkpoint)
  # and run settings such as the migration user's id.
  class Tracking
    TABLES = {
      'id_map' => <<~SQL,
        entity VARCHAR(40) NOT NULL,
        src_id BIGINT NOT NULL,
        tgt_id BIGINT NOT NULL,
        uuid CHAR(38) NULL,
        src_creator INT NULL,
        src_changed_by INT NULL,
        src_voided_by INT NULL,
        migrated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (entity, src_id),
        KEY idx_id_map_tgt (entity, tgt_id)
      SQL
      'migration_log' => <<~SQL,
        log_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        logged_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        step VARCHAR(40) NOT NULL,
        entity VARCHAR(40) NOT NULL,
        src_id BIGINT NULL,
        reason VARCHAR(100) NOT NULL,
        detail VARCHAR(1000) NULL,
        KEY idx_log_reason (step, reason),
        KEY idx_log_entity (entity, src_id)
      SQL
      'checkpoint' => <<~SQL,
        step VARCHAR(40) NOT NULL PRIMARY KEY,
        last_src_id BIGINT NOT NULL,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
      SQL
      'settings' => <<~SQL
        name VARCHAR(50) NOT NULL PRIMARY KEY,
        value VARCHAR(255) NOT NULL
      SQL
    }.freeze

    attr_reader :name

    # Creates the tracking schema for a staging schema if it is not there yet.
    def self.for(staging, config:, schemas:, connection: ActiveRecord::Base.connection)
      name = config.tracking_db_for(staging)
      unless schemas.exists?(name)
        schemas.create!(name, role: 'tracking', status: 'ready', details: { 'source' => staging })
      end
      raise Error, "#{name} exists but was not created by this tool" unless schemas.find(name)

      new(name, connection: connection).tap(&:ensure_tables!)
    end

    def initialize(name, connection: ActiveRecord::Base.connection)
      @name = Config.validate_schema_name!(name)
      @db = connection
    end

    def ensure_tables!
      TABLES.each do |table, columns|
        @db.execute("CREATE TABLE IF NOT EXISTS #{table_name(table)} (#{columns}) CHARACTER SET utf8mb4")
      end
    end

    # Fully qualified, quoted table name, e.g. `aetc_20261007_migration`.`id_map`.
    def table_name(table)
      "#{@db.quote_table_name(@name)}.#{@db.quote_table_name(table)}"
    end

    def checkpoint(step)
      @db.select_value("SELECT last_src_id FROM #{table_name('checkpoint')} WHERE step = #{@db.quote(step)}").to_i
    end

    def save_checkpoint(step, last_src_id)
      @db.execute("INSERT INTO #{table_name('checkpoint')} (step, last_src_id) " \
                  "VALUES (#{@db.quote(step)}, #{last_src_id.to_i}) AS new " \
                  'ON DUPLICATE KEY UPDATE last_src_id = new.last_src_id')
    end

    def setting(key)
      @db.select_value("SELECT value FROM #{table_name('settings')} WHERE name = #{@db.quote(key)}")
    end

    def save_setting(key, value)
      @db.execute("INSERT INTO #{table_name('settings')} (name, value) " \
                  "VALUES (#{@db.quote(key)}, #{@db.quote(value.to_s)}) AS new " \
                  'ON DUPLICATE KEY UPDATE value = new.value')
    end

    def count(table)
      @db.select_value("SELECT COUNT(*) FROM #{table_name(table)}").to_i
    end
  end
end
