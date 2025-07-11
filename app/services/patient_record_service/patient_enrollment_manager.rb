# app/services/patient_record_service/patient_enrollment_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientEnrollmentManager < BaseSaver
    def enroll_program(patient_id, record)
      if PatientProgram.where(program_id: record[:program_id], patient_id: patient_id).exists?
        return false
      end

      new_patient_program = PatientProgram.create!(
        program_id: record[:program_id],
        date_enrolled: record[:encounter_datetime] || Time.now,
        location_id: record[:location_id],
        patient_id: patient_id
      )

      if new_patient_program.errors.empty?
        Rails.logger.info('Successfully created patient program')
        true
      else
        Rails.logger.error(new_patient_program.errors.full_messages)
        raise new_patient_program.errors.full_messages.join(', ')
      end
    end
  end
end