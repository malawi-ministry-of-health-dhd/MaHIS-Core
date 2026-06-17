# frozen_string_literal: true
module BuildPatientRecordService

module VisitService
    def safe_get_visits(record)
      begin
        {
          visitsDates: visits(record) || [],
          NCDVisitsDates: visits(record, 32) || [],
          OPDVisitsDates: visits(record, 14) || []
        }
      rescue StandardError => e
        Rails.logger.error("Error getting visits for patient: #{e.message}")
        { visitsDates: [], NCDVisitsDates: [], OPDVisitsDates: [] }
      end
    end

    private

    def visits(record, program_id = nil)
      return [] unless record
      
      begin
        program = program_id ? visit_program(program_id) : nil
        patient_service.find_patient_visit_dates(record, program)
      rescue StandardError => e
        Rails.logger.error("Error in visits method: #{e.message}")
        []
      end
    end
    
    def patient_service
      @patient_service ||= PatientService.new
    end

    def visit_program(program_id)
      @visit_programs_by_id ||= {}
      return @visit_programs_by_id[program_id] if @visit_programs_by_id.key?(program_id)

      @visit_programs_by_id[program_id] = Program.find_by(program_id: program_id)
    end
  end
end
