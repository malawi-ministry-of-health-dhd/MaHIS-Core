module Api
  module V1
    class NcdReportsController < ApplicationController
      def ncd_active_patients
        @current_date = Date.current
        @location_id = User.current.location_id

        base_patients = Patient.joins(encounters: [:program, :type])
                                .where(program: { program_id: 32 })
                                .where(encounters: { location_id: @location_id })
                                .where(encounter_type: { name: ['PATIENT REGISTRATION', 'REGISTRATION'] })
                                .distinct
        
        results = paginate(base_patients)

        total_records = base_patients.count

        render json: { count: total_records, results: results, }, status: :ok
      end
    end
  end
end
