# frozen_string_literal: true

module AetcMigration
  # Small SQL helper used by the migration steps. Rows are written with plain multi-row INSERTs, not
  # ActiveRecord models, so MaHIS callbacks, default scopes and audits do not run on migrated rows.
  # Dates are written exactly as read (no time-zone conversion).
  class Sql
    INSERT_CHUNK = 500

    attr_reader :db

    def initialize(connection = ActiveRecord::Base.connection)
      @db = connection
    end

    # Rows as hashes with string keys.
    def select(sql)
      @db.select_all(sql).to_a
    end

    def value(sql)
      @db.select_value(sql)
    end

    def values(sql)
      @db.select_values(sql)
    end

    def execute(sql)
      @db.execute(sql)
    end

    def quote(value)
      case value
      when nil then 'NULL'
      when Time, DateTime then "'#{value.strftime('%Y-%m-%d %H:%M:%S')}'"
      when Date then "'#{value.strftime('%Y-%m-%d')}'"
      when true then '1'
      when false then '0'
      else @db.quote(value)
      end
    end

    # "1, 2, 3" for an IN (...) list; "NULL" when empty so the SQL stays valid and matches nothing.
    def list(values)
      values = Array(values).compact.uniq
      values.empty? ? 'NULL' : values.map { |v| quote(v) }.join(', ')
    end

    def name(schema, table)
      "#{@db.quote_table_name(schema)}.#{@db.quote_table_name(table)}"
    end

    # Inserts rows (hashes with the same keys) in chunks. ignore: true skips rows that would
    # duplicate a unique key.
    def insert(table, rows, ignore: false)
      return 0 if rows.empty?

      columns = rows.first.keys
      rows.each_slice(INSERT_CHUNK) do |slice|
        values = slice.map { |row| "(#{columns.map { |c| quote(row[c]) }.join(', ')})" }
        @db.execute("INSERT #{'IGNORE ' if ignore}INTO #{table} " \
                    "(#{columns.map { |c| @db.quote_column_name(c) }.join(', ')}) " \
                    "VALUES #{values.join(', ')}")
      end
      rows.size
    end

    # {uuid => id} for rows of table whose uuid is in uuids.
    def ids_by_uuid(table, id_column, uuids)
      uuids = uuids.compact
      return {} if uuids.empty?

      uuids.each_slice(INSERT_CHUNK).each_with_object({}) do |slice, out|
        select("SELECT #{id_column} AS id, uuid FROM #{table} WHERE uuid IN (#{list(slice)})")
          .each { |r| out[r['uuid']] = r['id'] }
      end
    end
  end
end
