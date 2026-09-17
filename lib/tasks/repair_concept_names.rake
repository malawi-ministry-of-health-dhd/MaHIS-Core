# frozen_string_literal: true

namespace :concepts do
  desc 'Repair mojibake concept names introduced by the upstream metadata seed'
  task repair_names: :environment do
    load Rails.root.join('db', 'seeds', 'concept_name_repairs_seed.rb')
    ConceptNameRepairs.run!
  end
end
