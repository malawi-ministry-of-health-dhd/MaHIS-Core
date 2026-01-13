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
          total_diagnosis: DiagnosisService.new.find_diagnosis({
                                                                 id: ConceptName.find_by(name: 'Qech outpatient diagnosis list')&.concept_id, name: nil, count: true
                                                               }),
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
    end
  end
end
