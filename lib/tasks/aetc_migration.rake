# frozen_string_literal: true

# AETC -> MaHIS-core data migration. Code: app/services/aetc_migration.
namespace :aetc do
  desc 'Show the AETC migration settings (MySQL server, target database, schemas, mappings folder)'
  task config: :environment do
    AetcMigration::Cli.run(:config)
  end

  desc 'Load an AETC mysqldump (.sql or .sql.gz) into a new schema: rake "aetc:load[/path/dump.sql]" ' \
       '(optional 2nd arg: schema name, default aetc_YYYYMMDD)'
  task :load, %i[path name] => :environment do |_task, args|
    AetcMigration::Cli.run(:load_dump, args[:path], args[:name])
  end

  desc 'Check everything before migrating: AETC tables, mappings (loaded and validated), MaHIS metadata, ' \
       'unmapped AETC data, and that MaHIS has no AETC data yet'
  task check: :environment do
    AetcMigration::Cli.run(:check)
  end

  desc 'Migrate the AETC data into MaHIS: rake aetc:migrate, or one step: rake "aetc:migrate[persons]". ' \
       'DRY_RUN=1 rolls everything back; LIMIT=n migrates only the next n AETC persons'
  task :migrate, %i[step] => :environment do |_task, args|
    AetcMigration::Cli.run(:migrate, args[:step])
  end

  desc 'List the schemas this tool created (AETC staging copies and tracking schemas)'
  task schemas: :environment do
    AetcMigration::Cli.run(:schemas)
  end

  desc 'Drop schemas this tool created, after typing each name (tracking data is exported to CSV first). ' \
       'Optional: rake "aetc:cleanup[schema_name]"'
  task :cleanup, %i[schema] => :environment do |_task, args|
    AetcMigration::Cli.run(:cleanup, args[:schema])
  end
end
