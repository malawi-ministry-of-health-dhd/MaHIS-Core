module Api
  module V1
    class NcdReportsController < ApplicationController
      
      # Main endpoint - uses direct SQL query
      def ncd_active_patients
        filters = params.permit(%i[given_name middle_name family_name birthdate gender per_page page])
        @location_id = User.current.location_id

        query_service = NcdActivePatientService.new(@location_id)
        results = query_service.get_active_patients(filters.to_h)

        render json: results, status: :ok
      rescue StandardError => e
        render json: { error: e.message }, status: :internal_server_error
      end
    end
  end
end