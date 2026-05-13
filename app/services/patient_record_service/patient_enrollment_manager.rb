# frozen_string_literal: true

module PatientRecordService
  class PatientEnrollmentManager < BaseSaver
    def enroll_program(patient_id, record)
      enrollments = pending_enrollments(record)
      return ok if enrollments.empty?

      errors = []

      ActiveRecord::Base.transaction do
        Patient.lock.find(patient_id)
        enrollments.each { |enroll| process_enrollment(patient_id, enroll, record, errors) }
      end

      OperationResult.new(success: true, errors: errors)
    rescue StandardError => e
      log_and_fail("Failed to create patient enrollment", e)
    end

    private

    def pending_enrollments(record)
      items = Array.wrap(record[:activePrograms])
      items.select { |item| item.present? && value_for(item, :status) == "unsaved" }
           .uniq { |item| value_for(item, :program_id).to_s }
    end

    def process_enrollment(patient_id, enroll, record, errors)
      program_id = value_for(enroll, :program_id)
      if program_id.blank?
        errors << "Program ID is missing for enrollment"
        return
      end

      date_completed = value_for(enroll, :date_completed)
      active = find_active_enrollment(patient_id, program_id)

      if active
        handle_existing_enrollment(active, patient_id, program_id, date_completed)
      else
        create_enrollment(patient_id, program_id, enroll, record, date_completed, errors)
      end
    end

    def find_active_enrollment(patient_id, program_id)
      PatientProgram.unscoped.where(
        program_id: program_id,
        patient_id: patient_id,
        voided: 0,
        date_completed: nil
      ).first
    end

    def handle_existing_enrollment(active, patient_id, program_id, date_completed)
      if date_completed.present?
        active.update!(date_completed: date_completed, patient_id: patient_id, program_id: program_id)
        Rails.logger.info("Completed enrollment #{active.patient_program_id} for patient #{patient_id} in program #{program_id}")
      else
        Rails.logger.info("Patient #{patient_id} already has an active enrollment in program #{program_id}, skipping")
      end
    end

    def create_enrollment(patient_id, program_id, enroll, record, date_completed, errors)
      location_id = resolve_location(enroll, record)

      PatientProgram.create!({
        program_id:     program_id,
        date_enrolled:  value_for(enroll, :date_enrolled) || Time.now,
        date_completed: date_completed,
        location_id:    location_id,
        patient_id:     patient_id
      }.compact)

      Rails.logger.info("Successfully enrolled patient #{patient_id} in program #{program_id} at location #{location_id}")
    rescue StandardError => e
      log_error("Failed to enroll patient #{patient_id} in program #{program_id}", e)
      errors << "Program #{program_id}: #{e.message}"
    end

    def resolve_location(enroll, record)
      value_for(enroll, :location_id) ||
        value_for(record, :location_id) ||
        Location.current&.location_id ||
        User.current&.location_id
    end

    def value_for(object, key)
      return nil if object.nil?

      hash = normalize_to_hash(object)
      return nil if hash.nil?

      hash[key] || hash[key.to_s]
    end

    def normalize_to_hash(object)
      if object.respond_to?(:to_unsafe_h)
        object.to_unsafe_h
      elsif object.is_a?(ActionController::Parameters)
        nil
      elsif object.respond_to?(:[])
        object
      elsif object.respond_to?(:to_h)
        object.to_h
      end
    end
  end
end
