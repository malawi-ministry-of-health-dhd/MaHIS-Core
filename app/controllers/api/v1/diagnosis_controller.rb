# frozen_string_literal: true

module Api
  module V1
    class DiagnosisController < ApplicationController
      before_action :authenticate

      def index
        filters = params.permit(:name)

        render json: paginate(service.find_diagnosis(filters[:name]))
      end

      private

      def service
        DiagnosisService.new
      end
    end
  end
end
