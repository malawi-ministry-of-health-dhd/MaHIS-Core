# frozen_string_literal: true

module Api
  module V1
    class ImpowController < ApplicationController
      before_action :authenticate

      # GET /api/v1/impow/expected_patients
      # Get patients expected for clinic day based on appointment dates
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      def expected_patients
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        page = params[:page] || 1
        per_page = params[:per_page] || 10

        program = Program.find(program_id)
        
        service = ImpowService::ExpectedPatientsEngine.new(
          program: program,
          date: date,
          page: page,
          per_page: per_page
        )
        
        result = service.fetch_expected_patients

        render json: result
      end
    end
  end
end
