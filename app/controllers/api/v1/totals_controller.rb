# frozen_string_literal: true

module Api
  module V1
    class TotalsController < ApplicationController
      before_action :authenticate, except: %i[index]
      def index
        render json: {
          total_districts: District.all.count,
          total_TA: TraditionalAuthority.all.count,
          total_village: Village.all.count,
          total_relationships: RelationshipType.all.count,
          total_programs: Program.all.count,
          total_concept_names: ConceptName.where('voided = 0 AND name IS NOT NULL AND name != ""').count,
          total_concept_set: concept_sets_count,
          total_OPD_drugs: Drug.find_all_by_concept_set('OPD Medication').count,
          total_test_types: Lab::ConceptsService.test_types.unscope(:select,
                                                                    :group).distinct.count('concept_name.concept_id'),
          total_specimens: Lab::ConceptsService.specimen_types.unscope(:select,
                                                                       :group).distinct.count('concept_name.concept_id'),
          total_diagnosis: diagnosis_count,
          total_facilities: Facility.all.count,
        }
      end

      def concept_sets_count
        ConceptName
          .joins('JOIN concept_set ON concept_name.concept_id = concept_set.concept_set')
          .where(voided: 0)
          .select('concept_name.concept_id')
          .group('concept_name.concept_id')
          .length
      end

      def diagnosis_count
        concept_set_id = ConceptName.find_by(name: 'ICD-10 Volume 3 Diagnosis', voided: 0)&.concept_id
        return 0 unless concept_set_id

        ConceptSet.where(concept_set: concept_set_id).distinct.count(:concept_id)
      end
    end
  end
end
