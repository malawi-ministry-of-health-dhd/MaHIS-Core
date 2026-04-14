# frozen_string_literal: true

# This migration ensures that the 'orders' and 'lab_lims_order_mappings' tables use the utf8_unicode_ci collation
# which is necessary for proper handling of Unicode characters in MySQL.
# It checks the current collation of these tables and converts them if necessary.
class FixTableCollations < ActiveRecord::Migration[8.1]
  TARGET_COLLATION = 'utf8_unicode_ci'
  TARGET_CHARSET   = 'utf8'

  TARGET_TABLES = %w[
    orders
    lab_lims_order_mappings
  ].freeze

  def up
    say 'Fixing table collations...', true

    TARGET_TABLES.each do |table|
      result = execute(<<~SQL).first
        SELECT TABLE_COLLATION
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = '#{table}'
      SQL

      table_collation = result&.first

      if table_collation && table_collation != TARGET_COLLATION
        say "Converting #{table} (#{table_collation} → #{TARGET_COLLATION})", true

        execute <<~SQL
          ALTER TABLE `#{table}`
          CONVERT TO CHARACTER SET #{TARGET_CHARSET}
          COLLATE #{TARGET_COLLATION}
        SQL
      else
        say "Skipping #{table} (already correct)", true
      end
    rescue StandardError => e
      raise ActiveRecord::IrreversibleMigration, "Failed on #{table}: #{e.message}"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Cannot safely revert collation changes'
  end
end
