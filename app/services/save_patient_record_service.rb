# app/services/save_patient_record_service.rb
# frozen_string_literal: true

class SavePatientRecordService
  ENCOUNTER_TYPE_MAPPING = {
    vitals: 'VITALS',
    diagnosis: 'DIAGNOSIS',
    substance_abuse: 'ASSESSMENT',
    screening: 'SCREENING',
    lab_orders: 'LAB ORDERS',
    lab_results: 'LAB RESULTS',
    family_medical_history: 'FAMILY MEDICAL HISTORY',
    complications: 'COMPLICATIONS',
    tb_reception: 'TB RECEPTION',
    hiv_status_at_enrollment: 'HIV STATUS AT ENROLLMENT',
    medical_history: 'MEDICAL HISTORY',
    patient_registration: 'PATIENT REGISTRATION',
    patient_outcome: 'PATIENT OUTCOME',
    treatment: 'TREATMENT',
    notes: 'NOTES',
    allergies: 'MEDICAL HISTORY'
  }.freeze

 
  def create_patient_record(record)
    # Extract required fields and initial validations (unchanged)
    required_fields = {
      program_id: record.dig('program_id'),
      provider_id: record.dig('provider_id'),
      location_id: record.dig('location_id'),
      encounter_datetime: record.dig('encounter_datetime')
    }
    ids = {
      national_id: record.dig('otherPersonInformation', 'nationalID'),
      ichis_id: record.dig('otherPersonInformation', 'ichisID'),
      birth_id: record.dig('otherPersonInformation', 'birthID')
    }

    return if required_fields.values.any? { |value| value.nil? || value.to_s.empty? }

    # Initialize managers/savers
    # (Initialize all here as before)
    identity_manager = PatientRecordService::PatientIdentityManager.new
    guardian_manager = PatientRecordService::GuardianManager.new
    enrollment_manager = PatientRecordService::PatientEnrollmentManager.new
    clinical_data_saver = PatientRecordService::ClinicalDataSaver.new
    lab_data_manager = PatientRecordService::LabDataManager.new
    vaccine_manager = PatientRecordService::VaccineManager.new
    appointment_manager = PatientRecordService::AppointmentManager.new
    sms_manager = PatientRecordService::SmsManager.new
    outcome_saver = PatientRecordService::OutcomeSaver.new
    medication_order_saver = PatientRecordService::MedicationOrderSaver.new
    dispensation_saver = PatientRecordService::DispensationSaver.new
    observation_saver = PatientRecordService::ObservationSaver.new

    # Save person information and get patient_id
    identity_data = identity_manager.save_person_information(record)
    return unless (patient_id = identity_data[:patient_id])

    # --- Initial ID Validation ---
    # This block is for an early check. If this fails, you might want to stop immediately.
    id_validation_success = identity_manager.validate_ids(ids[:national_id], ids[:birth_id], ids[:ichis_id])
    unless id_validation_success
      Rails.logger.warn("Patient ID validation failed for patient #{patient_id}. Terminating record creation.")
      patient_record = PatientRecord.find_or_initialize_by(patient_id: patient_id)
      patient_record.update(sync_status: 'failed', last_sync_at: Time.current, error_message: 'ID Validation Failed')
      return # Exit early
    end

    results = {} # Initialize a hash to store all operation results

    overall_sync_status = 'synced' # Assume success until a failure is detected

    ActiveRecord::Base.transaction do
      # --- Execute Operations and Capture Results ---
      results[:update_person_info] = identity_manager.update_person_information(patient_id, record)
      results[:manage_guardian] = guardian_manager.manage_guardian(patient_id, record)
      results[:enroll_program] = enrollment_manager.enroll_program(patient_id, record)
      results[:save_birthday_data] = clinical_data_saver.save_birthday_data(patient_id, record)
      results[:save_vitals_data] = clinical_data_saver.save_vitals_data(patient_id, record)
      results[:save_diagnosis_data] = clinical_data_saver.save_diagnosis_data(patient_id, record)
      results[:save_enrollment_data] = clinical_data_saver.save_enrollment_data(patient_id, record)
      results[:save_substance_abuse_data] = clinical_data_saver.save_substance_abuse_data(patient_id, record)
      results[:save_screening_data] = clinical_data_saver.save_screening_data(patient_id, record)
      results[:save_lab_orders_data] = lab_data_manager.save_lab_orders_data(patient_id, record)
      results[:save_lab_results_data] = lab_data_manager.save_lab_results_data(patient_id, record)
      results[:save_vaccines] = vaccine_manager.save_vaccines(patient_id, record)
      results[:save_appointments] = appointment_manager.save_appointments(patient_id, record)
      results[:send_sms] = sms_manager.send_sms(patient_id, record)
      results[:void_vaccine] = vaccine_manager.void_vaccine(patient_id, record)
      results[:void_lab_order] = lab_data_manager.void_lab_order(patient_id, record)
      results[:save_outcome] = outcome_saver.save_outcome(patient_id, record)
      results[:save_medication_order] = medication_order_saver.save_medication_order(patient_id, record)
      results[:create_ncd_identifier] = identity_manager.create_ncd_identifier(patient_id, record)
      results[:save_notes_and_pharmalogical_notes] = observation_saver.save_notes_and_pharmalogical_notes(patient_id, record)
      results[:save_allergies] = observation_saver.save_allergies(patient_id, record)
      results[:save_dispensation_data] = dispensation_saver.save_dispensation_data(patient_id, record)
      results[:save_all_observations] = observation_saver.save_all_observations(patient_id, record)

      # --- Post-Execution Checks on Individual Operations (using _key) ---
      failed_operations = []

      results.each do |key, success|
        unless success
          failed_operations << key
          Rails.logger.error("Operation '#{key}' failed for patient #{patient_id}.")
          # You can add specific handling here for specific keys:
          # if key == :save_vitals_data
          #   Rails.logger.error("Vitals data was critical and failed!")
          #   # Perhaps raise ActiveRecord::Rollback if this specific failure should halt the entire process
          # end
        end
      end

      if failed_operations.any?
        Rails.logger.error("Overall record saving for patient #{patient_id} had failures in: #{failed_operations.join(', ')}")
        overall_sync_status = 'partial_failed' # Or just 'failed' if any failure means total failure
        # If you want to force a rollback on *any* failure among these, uncomment the line below:
        # raise ActiveRecord::Rollback # This will cause the transaction to revert all changes
      else
        Rails.logger.info("All sub-operations successfully processed for patient #{patient_id}.")
        overall_sync_status = 'synced'
      end

    rescue StandardError => e
      # This catches any unhandled exceptions that propagate up from sub-services,
      # which would cause the transaction to rollback by default.
      Rails.logger.error("An unhandled error occurred during patient record saving for patient #{patient_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      overall_sync_status = 'failed' # Ensure status is 'failed' for unhandled errors
      raise # Re-raise to ensure the transaction is rolled back
    end # End of ActiveRecord::Base.transaction block

    # Building and updating the patient record (outside the transaction)
    patient_data = BuildPatientRecordService.build_patient_record(patient_id)
    patient_record = PatientRecord.find_or_initialize_by(patient_id: patient_id)

    if patient_data.nil?
      Rails.logger.error("Failed to build patient data for patient #{patient_id} post-operations.")
      patient_record.update(sync_status: 'failed', last_sync_at: Time.current, error_message: 'Failed to build final patient data')
      return
    end

    # Update the record with the determined sync status
    patient_record.record = patient_data
    patient_record.encounter_datetime = patient_data[:encounter_datetime] if patient_data[:encounter_datetime]
    patient_record.last_sync_at = Time.current
    patient_record.sync_status = overall_sync_status # Use the calculated status
    patient_record.save!

    # You could return the `results` hash from `create_patient_record` if an external caller needs it.
    # return results
    Rails.logger.info("############################################===========All sub-operations successfully processed for patient #{results}.")
    patient_data
  end
end