# frozen_string_literal: true

module Api
  module V1
    class TotalsController < ApplicationController
      before_action :authenticate, except: %i[index]
      def index
         render json: {
          total_districts: District.all.count,
          total_TA:TraditionalAuthority.all.count,
          total_village: Village.all.count,
          total_relationships: RelationshipType.all.count,
          total_patients: total_patients,
          total_programs: Program.all.count,
          total_concept_names:  ConceptName.where('voided = 0 AND name IS NOT NULL AND name != ""').count,
          total_concept_set: concept_sets_count
        }
      end
      def concept_sets_count
        ConceptName
        .joins("JOIN concept_set ON concept_name.concept_id = concept_set.concept_set")
        .where(voided: 0)
        .select("concept_name.concept_id")
        .group("concept_name.concept_id")
        .length
      end
      def total_patients
        Patient.joins(:encounters).where('encounter.location_id = ?', location_id).distinct.count
      end
    end
  end
end
