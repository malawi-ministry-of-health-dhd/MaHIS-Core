module Api
  module V1
    class NcdReportsController < ApplicationController
      def ncd_active_patients
        filters = params.permit(%i[given_name middle_name family_name birthdate gender per_page page])
        @current_date = Date.current
        @location_id = User.current.location_id

        base_patients = Patient.joins(encounters: [:program, :type])
                              .where(program: { program_id: 32 })
                              .where(encounters: { location_id: @location_id })
                              .where(encounter_type: { name: ['PATIENT REGISTRATION', 'REGISTRATION'] })
                              .distinct

        if filters[:given_name].present? || filters[:family_name].present? || filters[:gender].present?
          filtered_patients = service.find_patients_by_name_and_gender(
            filters[:given_name], 
            filters[:middle_name], 
            filters[:family_name], 
            filters[:gender]
          )
          base_patients = base_patients.merge(filtered_patients)
        end
        
        base_patients = base_patients.joins(:person).where(person: { birthdate: filters[:birthdate] }) if filters[:birthdate].present?

        total_records = base_patients.count
        results = paginate(base_patients)

        render json: { 
          count: total_records, 
          results: results
        }, status: :ok
      end

      private

      def service
        PatientService.new
      end
    end
  end
end