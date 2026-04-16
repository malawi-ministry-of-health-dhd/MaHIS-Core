# frozen_string_literal: true

module Api
  module V1
    class ConceptSetsController < ApplicationController
      def show
        render json: ConceptName.where("s.concept_set = ?
      AND concept_name.name LIKE (?)", params[:id],
                                       "%#{params[:name]}%").joins("INNER JOIN concept_set s ON
      s.concept_id = concept_name.concept_id").group('concept_name.concept_id')
      end
      def concept_sets_ids
        ActiveRecord::Base.connection.execute("SET SESSION group_concat_max_len = 1000000")
        @concept_sets = ConceptName
          .select("concept_name.name AS concept_set_name,
                   concept_name.concept_id AS concept_set_id, 
                   COALESCE(GROUP_CONCAT(DISTINCT concept_set.concept_id), '') AS member_ids")
          .joins("JOIN concept_set ON concept_name.concept_id = concept_set.concept_set")
          .where(voided: 0)
          .group("concept_name.concept_id")
          .order("concept_name.name")
      
        paginated_sets = paginate(@concept_sets)
      
        transformed_data = paginated_sets.map do |result|
          {
            id: result.concept_set_id,
            concept_set_name: result.concept_set_name,
            member_ids: result.member_ids.split(",").map(&:to_i)
          }
        end
      
        render json: transformed_data
      end

      def radiology_set
        render json: RadiologyService::Investigation.radiology_concept_set(params[:id])
      end
    end
  end
end
