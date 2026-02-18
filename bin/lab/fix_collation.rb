#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage:
#   bin/rails runner bin/fix_table_collations.rb --dry-run
#   bin/rails runner bin/fix_table_collations.rb

class CollationFixer
  TARGET_COLLATION = 'utf8_unicode_ci'
  TARGET_CHARSET   = 'utf8'

  TARGET_TABLES = %w[
    orders
    lab_lims_order_mappings
  ].freeze

  def initialize(dry_run: false)
    @dry_run = dry_run
    @fixed_tables = []
    @errors = []
  end

  def run
    puts "Collation Fixer (Scoped)"
    puts "=" * 80
    puts "Tables: #{TARGET_TABLES.join(', ')}"
    puts "Target: #{TARGET_CHARSET} / #{TARGET_COLLATION}"
    puts "Mode: #{@dry_run ? 'DRY RUN' : 'LIVE'}"
    puts "=" * 80

    check_tables

    unless @dry_run
      puts "\n⚠️  About to modify #{@fixed_tables.count} tables."
      puts "Press Ctrl+C to cancel, or Enter to continue..."
      STDIN.gets
    end

    fix_tables unless @dry_run
    print_summary
  end

  private

  def check_tables
    puts "\n🔍 Scanning selected tables...\n"

    TARGET_TABLES.each do |table|
      begin
        result = ActiveRecord::Base.connection.execute(<<~SQL).first
          SELECT TABLE_COLLATION
          FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_NAME = '#{table}'
        SQL

        table_collation = result&.first

        if table_collation && table_collation != TARGET_COLLATION
          puts "  ⚠️  Table: #{table} (#{table_collation})"
          @fixed_tables << table
        end

      rescue StandardError => e
        @errors << "Error checking table #{table}: #{e.message}"
      end
    end
  end

  def fix_tables
    puts "\n🔧 Fixing table collations...\n"

    @fixed_tables.each do |table|
      begin
        sql = <<~SQL
          ALTER TABLE `#{table}`
          CONVERT TO CHARACTER SET #{TARGET_CHARSET}
          COLLATE #{TARGET_COLLATION}
        SQL

        puts "  ✓ Converting #{table}"
        ActiveRecord::Base.connection.execute(sql)
      rescue StandardError => e
        error = "Failed to convert #{table}: #{e.message}"
        @errors << error
        puts "  ✗ #{error}"
      end
    end
  end

  def print_summary
    puts "\n" + "=" * 80
    puts "📊 Summary"
    puts "=" * 80
    puts "Tables processed: #{@fixed_tables.count}"

    if @errors.any?
      puts "\n❌ Errors:"
      @errors.each { |e| puts "  - #{e}" }
    elsif @dry_run
      puts "\n💡 Re-run without --dry-run to apply changes"
    else
      puts "\n✅ Illegal mix of collation fixed successfully!"
    end
    puts "=" * 80
  end
end

# ---- execution ----
if __FILE__ == $PROGRAM_NAME || caller.any? { |c| c.include?('rails/commands/runner') }
  dry_run = ARGV.include?('--dry-run')
  CollationFixer.new(dry_run: dry_run).run
end
