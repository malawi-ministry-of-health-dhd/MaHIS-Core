# frozen_string_literal: true

require Rails.root.join('lib', 'tidb_support').to_s
require Rails.root.join('lib', 'tidb_reporting').to_s

namespace :db do
  namespace :tidb do
    desc 'Verify that the configured database is ready to run MAHIS on TiDB'
    task check: :environment do
      connection = ActiveRecord::Base.connection
      server_version = TidbSupport.version_string(connection)

      abort "Not connected to TiDB (server reported #{server_version.inspect})" unless server_version.match?(/tidb/i)

      TidbSupport.verify_supported!(connection)

      transaction_mode = connection.select_value('SELECT @@SESSION.tidb_txn_mode').to_s.downcase
      abort "TiDB transaction mode must be pessimistic; found #{transaction_mode.inspect}" unless transaction_mode == 'pessimistic'

      foreign_key_checks = connection.select_value('SELECT @@SESSION.foreign_key_checks').to_i
      abort 'TiDB foreign_key_checks must be enabled for application traffic' unless foreign_key_checks == 1

      missing_primary_keys = connection.select_values(<<~SQL)
        SELECT tables.TABLE_NAME
        FROM information_schema.TABLES tables
        LEFT JOIN information_schema.TABLE_CONSTRAINTS constraints
          ON constraints.CONSTRAINT_SCHEMA = tables.TABLE_SCHEMA
         AND constraints.TABLE_NAME = tables.TABLE_NAME
         AND constraints.CONSTRAINT_TYPE = 'PRIMARY KEY'
        WHERE tables.TABLE_SCHEMA = DATABASE()
          AND tables.TABLE_TYPE = 'BASE TABLE'
          AND constraints.CONSTRAINT_NAME IS NULL
        ORDER BY tables.TABLE_NAME
      SQL

      zero_date_defaults = connection.select_values(<<~SQL)
        SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME)
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND CAST(COLUMN_DEFAULT AS CHAR) LIKE '0000-00-00%'
        ORDER BY TABLE_NAME, ORDINAL_POSITION
      SQL

      foreign_key_count = connection.select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM information_schema.TABLE_CONSTRAINTS
        WHERE CONSTRAINT_SCHEMA = DATABASE()
          AND CONSTRAINT_TYPE = 'FOREIGN KEY'
      SQL

      routine_count = connection.select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
      SQL

      ssl_cipher = connection.select_rows("SHOW STATUS LIKE 'Ssl_cipher'").dig(0, 1).to_s
      if ENV['TIDB_REQUIRE_TLS'] == 'true' && ssl_cipher.empty?
        abort 'TIDB_REQUIRE_TLS=true, but the current database connection is not using TLS'
      end

      puts "TiDB version: #{TidbSupport.version(connection)}"
      puts "Transaction mode: #{transaction_mode}"
      puts "TLS: #{ssl_cipher.empty? ? 'not active' : ssl_cipher}"
      puts "Foreign keys: #{foreign_key_count}"
      puts "Stored routines: #{routine_count} (deferred for TiDB)"
      puts "Tables without primary keys: #{missing_primary_keys.length}"
      puts "  #{missing_primary_keys.join(', ')}" if missing_primary_keys.any?
      puts "Zero-date defaults: #{zero_date_defaults.length}"
      puts "  #{zero_date_defaults.join(', ')}" if zero_date_defaults.any?
      puts 'TiDB readiness checks passed.'
    end

    namespace :tiflash do
      desc 'Create TiFlash replicas for the MAHIS reporting tables'
      task configure: :environment do
        connection = ActiveRecord::Base.connection
        TidbSupport.verify_supported!(connection)
        abort 'TiFlash replicas can only be configured on TiDB' unless TidbSupport.enabled?(connection)

        base_tables = connection.select_values(<<~SQL)
          SELECT TABLE_NAME
          FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_TYPE = 'BASE TABLE'
        SQL

        requested_tables = ENV.fetch('TABLES', TidbReporting::REPLICA_TABLES.join(',')).split(',').map(&:strip)
        requested_tables.each do |table_name|
          unless base_tables.include?(table_name)
            warn "Skipping missing table #{table_name}"
            next
          end

          quoted_table = connection.quote_table_name(table_name)
          connection.execute("ALTER TABLE #{quoted_table} SET TIFLASH REPLICA 1")
          puts "Requested TiFlash replica for #{table_name}"
        end
      end

      desc 'Wait for all configured MAHIS TiFlash replicas to become available'
      task wait: :environment do
        timeout = ENV.fetch('TIMEOUT', 600).to_i
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        loop do
          replicas = TidbReporting.tiflash_replicas
          expected = TidbReporting::REPLICA_TABLES
          unavailable = expected.reject do |table_name|
            replicas.any? { |row| row['TABLE_NAME'] == table_name && row['AVAILABLE'].to_i == 1 }
          end

          break puts('All MAHIS TiFlash replicas are available.') if unavailable.empty?

          abort "Timed out waiting for TiFlash replicas: #{unavailable.join(', ')}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          puts "Waiting for TiFlash replicas: #{unavailable.join(', ')}"
          sleep 5
        end
      end

      desc 'Show MAHIS TiFlash replica availability and progress'
      task status: :environment do
        replicas = TidbReporting.tiflash_replicas.index_by { |row| row['TABLE_NAME'] }
        TidbReporting::REPLICA_TABLES.each do |table_name|
          replica = replicas[table_name]
          puts format('%-40s available=%-3s progress=%s', table_name,
                      replica ? replica['AVAILABLE'] : 'no', replica ? replica['PROGRESS'] : '0')
        end
      end
    end

    namespace :reporting do
      desc 'Refresh set-based ART reporting facts used by TiFlash reports'
      task refresh: :environment do
        count = Reporting::PatientArtFactsRefresh.call
        puts "Refreshed #{count} ART reporting fact rows."
      end
    end
  end
end
