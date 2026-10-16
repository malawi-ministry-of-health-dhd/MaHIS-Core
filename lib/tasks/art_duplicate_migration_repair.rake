# frozen_string_literal: true

namespace :patients do
  desc 'Run the ART duplicate rollback followed by demographic repair'
  task repair_art_duplicate_migration: :environment do
    ArtDuplicateMigrationRepairTask.new.run
  end
end
