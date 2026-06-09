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
        handle_existing_enrollment(active, patient_id, program_id, enroll, date_completed)
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

    def handle_existing_enrollment(active, patient_id, program_id, enroll, date_completed)
      if date_completed.present?
        active.update!(date_completed: date_completed, patient_id: patient_id, program_id: program_id)
        Rails.logger.info("Completed enrollment #{active.patient_program_id} for patient #{patient_id} in program #{program_id}")
      else
        Rails.logger.info("Patient #{patient_id} already has an active enrollment in program #{program_id}, skipping enrollment creation")
      end
      process_patient_states(active, program_id, enroll)
    end

    def create_enrollment(patient_id, program_id, enroll, record, date_completed, errors)
      location_id = resolve_location(enroll, record)

      patient_program = PatientProgram.create!({
        program_id:     program_id,
        date_enrolled:  value_for(enroll, :date_enrolled) || Time.now,
        date_completed: date_completed,
        location_id:    location_id,
        patient_id:     patient_id
      }.compact)

      Rails.logger.info("Successfully enrolled patient #{patient_id} in program #{program_id} at location #{location_id}")
      process_patient_states(patient_program, program_id, enroll)
    rescue StandardError => e
      log_error("Failed to enroll patient #{patient_id} in program #{program_id}", e)
      errors << "Program #{program_id}: #{e.message}"
    end

    def process_patient_states(patient_program, program_id, enroll)
      states = Array.wrap(value_for(enroll, :patient_states))
      return if states.empty?

      states.each do |state_entry|
        state_name = value_for(state_entry, :name)
        start_date = value_for(state_entry, :start_date)

        next if state_name.blank?

        workflow_state = ProgramWorkflowState.find_by_name_and_program(name: state_name, program_id: program_id)
        unless workflow_state
          Rails.logger.warn("ProgramWorkflowState '#{state_name}' not found for program #{program_id}, skipping")
          next
        end

        close_current_state(patient_program, start_date || Time.now)
        PatientState.create!(
          patient_program: patient_program,
          state: workflow_state.program_workflow_state_id,
          start_date: start_date || Time.now
        )
        Rails.logger.info("Created state '#{state_name}' for patient_program #{patient_program.patient_program_id}")
      end
    rescue StandardError => e
      Rails.logger.error("Failed to process patient states for patient_program #{patient_program&.patient_program_id}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      raise
    end

    def close_current_state(patient_program, end_date)
      current_state = PatientState.where(patient_program: patient_program, end_date: nil)
                                  .where('start_date <= ?', end_date)
                                  .order(start_date: :desc)
                                  .first
      return unless current_state

      current_state.update!(end_date: end_date)
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
