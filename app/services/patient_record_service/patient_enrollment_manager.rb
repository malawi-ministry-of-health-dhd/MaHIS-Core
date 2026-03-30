# app/services/patient_record_service/patient_enrollment_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientEnrollmentManager < BaseSaver
    def enroll_program(patient_id, record)
      enrollment = record[:activePrograms]
      return ok if enrollment.blank?

      enrollments        = enrollment.is_a?(Array) ? enrollment : [enrollment]
      unsaved_enrollments = enrollments.select { |item| item.present? && item[:status] == "unsaved" }
      return ok if unsaved_enrollments.empty?

      collected_errors = []

      ActiveRecord::Base.transaction do
        unsaved_enrollments.each do |enroll|
          next unless enroll

          if PatientProgram.where(program_id: enroll[:program_id], patient_id: patient_id).exists?
            Rails.logger.info("Patient #{patient_id} already enrolled in program #{enroll[:program_id]}, skipping")
            next
          end

          begin
            PatientProgram.create!(
              program_id:    enroll[:program_id],
              date_enrolled: enroll[:date_enrolled] || Time.now,
              location_id:   enroll[:location_id],
              patient_id:    patient_id
            )
            Rails.logger.info("Successfully enrolled patient #{patient_id} in program #{enroll[:program_id]}")
          rescue StandardError => e
            log_error("Failed to enroll patient #{patient_id} in program #{enroll[:program_id]}", e)
            collected_errors << "Program #{enroll[:program_id]}: #{e.message}"
            # continues to next enrollment
          end
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Failed to create patient enrollment", e)
    end
  end
end