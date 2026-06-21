# frozen_string_literal: true

# Display-name columns in the OpenMRS-derived schema are matched and searched
# case-insensitively all over the app:
#   EncounterType.find_by_name('DISPENSING')          # stored "Dispensing"
#   PatientIdentifierType.find_by_name('NCD Number')  # stored "Ncd number"
#   Drug.where('name LIKE ?', "%lume%")               # stored "Lumefantrine..."
#
# The original MySQL deployment used case-insensitive collations, so these
# matched. The TiDB import recreated the `name`/`short_name` columns with
# case-sensitive `*_bin` collations, so every such lookup whose literal case
# differs from the stored data silently returns nothing — surfacing as 500s,
# NoMethodError-on-nil, and empty search results across NCD, dispensing, the
# drug list, address pickers, etc.
#
# This flips every `name`/`short_name` column that is still case-sensitive to a
# case-insensitive collation of the same charset. It is idempotent and safe to
# re-run, and is invoked from BOTH the migration and db/seeds.rb so a metadata
# re-import (which resets columns to `*_bin`) gets corrected again.
module ReferenceNameCollation
  # Columns treated as display names. Deliberately NOT `identifier` (different
  # match semantics) or `uuid` (must stay binary).
  COLUMN_NAMES = %w[name short_name].freeze

  # Case-insensitive collation per charset. latin1 is intentionally absent: TiDB
  # has no case-insensitive latin1 collation and rejects charset changes, so
  # latin1 columns are skipped (there are only a few, none case-searched).
  CI_COLLATION = {
    'utf8'    => 'utf8_general_ci',
    'utf8mb3' => 'utf8_general_ci',
    'utf8mb4' => 'utf8mb4_general_ci'
  }.freeze

  module_function

  # Make every case-sensitive display-name column case-insensitive. Returns the
  # list of "table.column -> collation" changes applied.
  def enforce!(connection: ActiveRecord::Base.connection)
    return [] unless connection.adapter_name.to_s.match?(/mysql/i)

    changed = []
    skipped = []

    target_columns(connection).each do |col|
      collation = CI_COLLATION[col[:charset]]
      next if collation.nil? # unconvertible charset (e.g. latin1)

      ddl = +"ALTER TABLE `#{col[:table]}` MODIFY `#{col[:column]}` #{col[:type]} " \
             "CHARACTER SET #{col[:charset]} COLLATE #{collation} " \
             "#{col[:nullable] ? 'NULL' : 'NOT NULL'}"
      # TEXT/BLOB columns can't carry a DEFAULT; otherwise preserve it exactly.
      ddl << " DEFAULT #{connection.quote(col[:default])}" unless text_or_blob?(col[:type]) || col[:default].nil?

      # TiDB refuses to recollate an indexed column, so drop any indexes on it
      # first and recreate them afterwards. `ensure` guarantees a dropped index
      # is always restored, even if the MODIFY fails.
      indexes = indexes_on(connection, col[:table], col[:column])
      dropped = []
      begin
        indexes.each do |index|
          connection.execute("DROP INDEX `#{index[:name]}` ON `#{col[:table]}`")
          dropped << index
        end
        connection.execute(ddl)
        changed << "#{col[:table]}.#{col[:column]} -> #{collation}"
      rescue ActiveRecord::StatementInvalid => e
        skipped << "#{col[:table]}.#{col[:column]} (#{e.message.to_s.lines.first.to_s.strip})"
      ensure
        dropped.each { |index| connection.execute(create_index_sql(col[:table], index)) }
      end
    end

    log("ReferenceNameCollation: #{changed.empty? ? 'no changes needed' : "changed #{changed.size}: #{changed.join(', ')}"}")
    log("ReferenceNameCollation: SKIPPED #{skipped.join('; ')}") if skipped.any?
    changed
  end

  # All case-sensitive (`*_bin`) display-name columns in the current schema.
  def target_columns(connection)
    connection.select_all(<<~SQL).map do |r|
      SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, CHARACTER_SET_NAME
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = #{connection.quote(connection.current_database)}
        AND COLUMN_NAME IN (#{COLUMN_NAMES.map { |c| connection.quote(c) }.join(', ')})
        AND RIGHT(COLLATION_NAME, 4) = '_bin'
      ORDER BY TABLE_NAME, COLUMN_NAME
    SQL
      {
        table:    r['TABLE_NAME'],
        column:   r['COLUMN_NAME'],
        type:     r['COLUMN_TYPE'],
        nullable: r['IS_NULLABLE'] == 'YES',
        default:  r['COLUMN_DEFAULT'],
        charset:  r['CHARACTER_SET_NAME']
      }
    end
  end

  # Secondary indexes (excluding PRIMARY) that include the column, with ordered
  # columns / prefix lengths / uniqueness, so they recreate identically.
  def indexes_on(connection, table, column)
    db = connection.current_database
    index_names = connection.select_values(<<~SQL)
      SELECT DISTINCT INDEX_NAME
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = #{connection.quote(db)}
        AND TABLE_NAME   = #{connection.quote(table)}
        AND COLUMN_NAME  = #{connection.quote(column)}
        AND INDEX_NAME  <> 'PRIMARY'
    SQL

    index_names.map do |index_name|
      rows = connection.select_all(<<~SQL).to_a
        SELECT COLUMN_NAME, SUB_PART, NON_UNIQUE
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = #{connection.quote(db)}
          AND TABLE_NAME   = #{connection.quote(table)}
          AND INDEX_NAME   = #{connection.quote(index_name)}
        ORDER BY SEQ_IN_INDEX
      SQL
      {
        name:    index_name,
        unique:  rows.first['NON_UNIQUE'].to_i.zero?,
        columns: rows.map { |r| { name: r['COLUMN_NAME'], sub_part: r['SUB_PART'] } }
      }
    end
  end

  def create_index_sql(table, index)
    cols = index[:columns].map do |c|
      c[:sub_part] ? "`#{c[:name]}`(#{c[:sub_part]})" : "`#{c[:name]}`"
    end.join(', ')
    "CREATE #{'UNIQUE ' if index[:unique]}INDEX `#{index[:name]}` ON `#{table}` (#{cols})"
  end

  def text_or_blob?(type)
    type.to_s.match?(/\b(?:tiny|medium|long)?(?:text|blob)\b/i)
  end

  def log(message)
    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.info(message)
    else
      puts message
    end
  end
end
