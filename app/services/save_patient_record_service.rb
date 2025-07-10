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
    # Initial validation (can also be extracted to a validator class)
    required_fields = {
      program_id: record.dig('program_id'),
      provider_id: record.dig('provider_id'),
      location_id: record.dig('location_id'),
      encounter_datetime: record.dig('encounter_datetime')
    }
    return if required_fields.values.any? { |value| value.nil? || value.to_s.empty? }

    # Save person information and get patient_id
    identity_manager = PatientRecordService::PatientIdentityManager.new
    identity_data = identity_manager.save_person_information(record)
    return unless (patient_id = identity_data[:patient_id])

    identity_manager.validate_ids(record.dig('otherPersonInformation', 'nationalID'),
                                  record.dig('otherPersonInformation', 'birthID'),
                                  record.dig('otherPersonInformation', 'ichisID'))

    # Orchestrate calls to specialized services
    ActiveRecord::Base.transaction do
      # Using specific managers/savers
      identity_manager.update_person_information(patient_id, record)
      PatientRecordService::GuardianManager.new.manage_guardian(patient_id, record)
      PatientRecordService::PatientEnrollmentManager.new.enroll_program(patient_id, record)
      PatientRecordService::ClinicalDataSaver.new.save_birthday_data(patient_id, record)
      PatientRecordService::ClinicalDataSaver.new.save_vitals_data(patient_id, record)
      PatientRecordService::ClinicalDataSaver.new.save_diagnosis_data(patient_id, record)
      PatientRecordService::ClinicalDataSaver.new.save_enrollment_data(patient_id, record)
      PatientRecordService::ClinicalDataSaver.new.save_substance_abuse_data(patient_id, record)
      PatientRecordService::ClinicalDataSaver.new.save_screening_data(patient_id, record)
      PatientRecordService::LabDataManager.new.save_lab_orders_data(patient_id, record)
      PatientRecordService::LabDataManager.new.save_lab_results_data(patient_id, record)
      PatientRecordService::VaccineManager.new.save_vaccines(patient_id, record)
      PatientRecordService::AppointmentManager.new.save_appointments(patient_id, record)
      PatientRecordService::SmsManager.new.send_sms(patient_id, record)
      PatientRecordService::VaccineManager.new.void_vaccine(patient_id, record)
      PatientRecordService::LabDataManager.new.void_lab_order(patient_id, record)
      PatientRecordService::OutcomeSaver.new.save_outcome(patient_id, record)
      PatientRecordService::MedicationOrderSaver.new.save_medication_order(patient_id, record)
      identity_manager.create_ncd_identifier(patient_id, record)
      PatientRecordService::ObservationSaver.new.save_notes_and_pharmalogical_notes(patient_id, record)
      PatientRecordService::ObservationSaver.new.save_allergies(patient_id, record)
      PatientRecordService::DispensationSaver.new.save_dispensation_data(patient_id, record)
      PatientRecordService::ObservationSaver.new.save_all_observations(patient_id, record)
    end

    # Building and updating the patient record (can be another service)
    patient_data = BuildPatientRecordService.build_patient_record(patient_id)
    patient_record = PatientRecord.find_or_initialize_by(patient_id: patient_id)

    if patient_data.nil?
      Rails.logger.error("Failed to build data for patient #{patient_id}")
      patient_record.update(sync_status: 'failed', last_sync_at: Time.current)
      return
    end

    patient_record.record = patient_data
    patient_record.encounter_datetime = patient_data[:encounter_datetime] if patient_data[:encounter_datetime]
    patient_record.last_sync_at = Time.current
    patient_record.sync_status = 'synced'
    patient_record.save!

    patient_data
  end
end