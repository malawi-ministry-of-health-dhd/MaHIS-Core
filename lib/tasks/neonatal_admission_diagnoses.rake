# frozen_string_literal: true

namespace :neonatal_admission_diagnoses do
  desc 'Create/update Neonatal admission diagnoses concept set and members (idempotent)'
  task seed: :environment do
    NeonatalAdmissionDiagnoses::Seeder.seed!
    puts "Member concept IDs: #{NeonatalAdmissionDiagnoses.member_concept_ids.size}"
  end
end
