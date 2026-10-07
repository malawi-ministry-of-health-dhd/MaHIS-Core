# frozen_string_literal: true

# AETC -> MaHIS-core data migration. Code: app/services/aetc_migration.
namespace :aetc do
  desc 'Show the AETC migration settings (MySQL server, target database, schemas, mappings folder)'
  task config: :environment do
    AetcMigration::Cli.run(:config)
  end

  desc 'List the schemas this tool created (AETC staging copies and tracking schemas)'
  task schemas: :environment do
    AetcMigration::Cli.run(:schemas)
  end
end
