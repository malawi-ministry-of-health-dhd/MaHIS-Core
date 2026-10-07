# frozen_string_literal: true

namespace :patients do
  desc 'Review or reverse the August 2026 exact-duplicate merges for ART patients without deleting rows'
  task rollback_art_duplicate_merges: :environment do
    ArtDuplicateMergeRollbackTask.new.run
  end
end
