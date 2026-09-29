# frozen_string_literal: true

namespace :patients do
  desc 'Restore blank ART patient gender and birthdate from the pre-migration database'
  task repair_missing_art_demographics: :environment do
    ArtMissingDemographicsRepairTask.new.run
  end
end
