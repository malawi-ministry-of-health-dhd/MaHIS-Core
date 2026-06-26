# frozen_string_literal: true

module Api
  module V1
    class DiagnosisController < ApplicationController
      before_action :authenticate

      def index
        filters = params.permit(:id, :name)

        render json: paginate(service.find_diagnosis(filters[:name], concept_set_id: filters[:id]))
      end

      private

      def service
        DiagnosisService.new
      end
    end
  end
end
