# frozen_string_literal: true

require Rails.root.join('lib', 'database_sql_importer').to_s
require Rails.root.join('lib', 'tidb_support').to_s

class LoadMahisSkeleton < ActiveRecord::Migration[7.0]
  def up
    tidb = TidbSupport.enabled?(connection)
    TidbSupport.verify_supported!(connection)

    say "Loading OpenMRS skeleton#{' for TiDB' if tidb}..."
    DatabaseSqlImporter.new(
      config: ActiveRecord::Base.connection_db_config.configuration_hash,
      file_path: Rails.root.join('db', 'mahis_skeleton.sql.gz'),
      skip_routines: tidb
    ).import!

    say 'Skipped stored routines because TiDB does not support them; function-dependent reports remain deferred.' if tidb
    say 'Harmonized database initialization complete.'
  end

  def down
    # Don't drop on rollback - skeleton is foundational
  end
end
