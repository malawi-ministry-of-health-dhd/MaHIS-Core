# frozen_string_literal: true

class SeedNeonatalAdmissionDiagnosesConceptSet < ActiveRecord::Migration[8.1]
  def up
    say_with_time 'Seeding Neonatal admission diagnoses concept set' do
      NeonatalAdmissionDiagnoses::Seeder.seed!
    end
  end

  def down
    say_with_time 'Removing Neonatal admission diagnoses concept set links (concepts retained)' do
      set_id = NeonatalAdmissionDiagnoses.concept_set_concept_id
      if set_id
        ConceptSet.where(concept_set: set_id).delete_all
        say "Removed concept_set rows for set concept_id=#{set_id}"
      else
        say 'Set concept not found; nothing to remove'
      end
    end
  end
end
