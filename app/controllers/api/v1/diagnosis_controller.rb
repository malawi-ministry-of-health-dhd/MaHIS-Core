# frozen_string_literal: true

module Api
  module V1
    class DiagnosisController < ApplicationController
      before_action :authenticate

      def index
        filters = params.permit(:id, :name, :concept_set_name)

        render json: paginate(
          service.find_diagnosis(
            filters[:name],
            concept_set_id: filters[:id],
            concept_set_name: filters[:concept_set_name]
          )
        )
      end

      # GET /api/v1/diagnosis/common — recent common diagnoses for the site,
      # used to populate the OPD "Common diagnoses" quick-pick.
      def common
        filters = params.permit(:limit, :since, :location_id)

        render json: service.recent_common_diagnoses(
          limit: filters[:limit] || 15,
          since: filters[:since],
          location_id: filters[:location_id]
        )
      end

      private

      def service
        DiagnosisService.new
      end
    end
  end
end
