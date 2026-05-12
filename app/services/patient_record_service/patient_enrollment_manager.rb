# app/services/patient_record_service/patient_enrollment_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientEnrollmentManager < BaseSaver
    def enroll_program(patient_id, record)
      enrollment = record[:activePrograms]
      return ok if enrollment.blank?

      enrollments        = enrollment.is_a?(Array) ? enrollment : [enrollment]
      unsaved_enrollments = enrollments.select { |item| item.present? && value_for(item, :status) == "unsaved" }
      unsaved_enrollments = unsaved_enrollments.uniq { |item| value_for(item, :program_id).to_s }
      return ok if unsaved_enrollments.empty?

      collected_errors = []

      ActiveRecord::Base.transaction do
        Patient.lock.find(patient_id)

        unsaved_enrollments.each do |enroll|
          next unless enroll

          program_id = value_for(enroll, :program_id)
          if program_id.blank?
            collected_errors << 'Program ID is missing for enrollment'
            next
          end
          
          if PatientProgram.unscoped.where(
            program_id: program_id,
            patient_id: patient_id,
            voided: 0
          ).exists?
            Rails.logger.info(
              "Patient #{patient_id} already enrolled in program #{program_id}, skipping"
            )
            next
          end

          begin
            location_id = value_for(enroll, :location_id) ||
                          value_for(record, :location_id) ||
                          Location.current&.location_id ||
                          User.current&.location_id

            PatientProgram.create!(
              program_id:    program_id,
              date_enrolled: value_for(enroll, :date_enrolled) || Time.now,
              location_id:   location_id,
              patient_id:    patient_id
            )
            Rails.logger.info(
              "Successfully enrolled patient #{patient_id} in program #{program_id} at location #{location_id}"
            )
          rescue StandardError => e
            log_error("Failed to enroll patient #{patient_id} in program #{program_id}", e)
            collected_errors << "Program #{program_id}: #{e.message}"
            # continues to next enrollment
          end
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Failed to create patient enrollment", e)
    end

    private

    def value_for(object, key)
      return nil if object.nil?

      if object.respond_to?(:[])
        value = object[key]
        return value unless value.nil?
        value = object[key.to_s]
        return value unless value.nil?
      end

      if object.respond_to?(:to_unsafe_h)
        hash = object.to_unsafe_h
        return hash[key] unless hash[key].nil?
        return hash[key.to_s] unless hash[key.to_s].nil?
      end

      # Avoid calling to_h on unpermitted ActionController::Parameters
      return nil if defined?(ActionController::Parameters) && object.is_a?(ActionController::Parameters)

      if object.respond_to?(:to_h)
        hash = object.to_h
        return hash[key] unless hash[key].nil?
        return hash[key.to_s] unless hash[key.to_s].nil?
      end

      nil
    end
  end
end
