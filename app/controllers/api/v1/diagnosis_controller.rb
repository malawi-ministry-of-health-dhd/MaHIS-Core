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

      private

      def service
        DiagnosisService.new
      end
    end
  end
end
