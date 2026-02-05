# frozen_string_literal: true

namespace :concepts do
  desc 'Sync ConceptNameDictionary.json with current concept names from database'
  task sync_dictionary: :environment do
    require_relative '../sync_concept_dictionary'
    ConceptDictionarySync.new.run
  end
end
