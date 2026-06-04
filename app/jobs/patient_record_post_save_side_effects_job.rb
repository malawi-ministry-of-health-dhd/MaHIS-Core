# frozen_string_literal: true

class PatientRecordPostSaveSideEffectsJob < ApplicationJob
  queue_as :patient_records

  NCD_PROGRAM_ID = 32
  IMMUNIZATION_REFRESH_OPERATIONS = %w[enroll_program save_vaccines void_vaccine].freeze
  MNH_REFRESH_OPERATIONS = %w[
    enroll_program
    save_all_observations
    save_lab_orders_data
    save_lab_results_data
    void_encounters
    void_lab_order
  ].freeze
  NCD_REFERRAL_SYNC_OPERATIONS = %w[
    create_ncd_identifier
    enroll_program
    save_all_observations
    save_dispensation_data
    save_medication_order
    void_drug_orders
  ].freeze

  def perform(patient_id, record, changed_operation_keys)
    @changed_operation_keys = Array(changed_operation_keys).map(&:to_s)
    record = (record || {}).with_indifferent_access

    refresh_immunization_dashboard_if_needed(record)
    refresh_mnh_stats_if_needed(record)
    sync_referral_results_if_needed(patient_id, record)
  end

  private

  def refresh_immunization_dashboard_if_needed(record)
    return unless operation_keys_include?(IMMUNIZATION_REFRESH_OPERATIONS)
    return unless immunization_record?(record)

    location_id = record[:location_id].presence || User.current&.location_id
    return if location_id.blank?

    today = Date.today
    start_date = today.beginning_of_year.to_s
    end_date = today.to_s
    ImmunizationReportJob.perform_later(start_date, end_date, location_id)
  rescue StandardError => e
    Rails.logger.error("Failed to queue immunization dashboard refresh: #{e.class}: #{e.message}")
  end

  def refresh_mnh_stats_if_needed(record)
    return unless operation_keys_include?(MNH_REFRESH_OPERATIONS)
    return if Sync::MnhStatsSyncJob.program_key_for_program_id(record_value(record, :program_id)).blank?

    Sync::MnhStatsSyncJob.enqueue_for_patient_record(record)
  rescue StandardError => e
    Rails.logger.error("Failed to queue MNH stats refresh: #{e.class}: #{e.message}")
  end

  def sync_referral_results_if_needed(patient_id, record)
    return unless operation_keys_include?(NCD_REFERRAL_SYNC_OPERATIONS)
    return unless ncd_record?(patient_id, record)

    patient = Patient.find_by(patient_id: patient_id)
    tei = referral_tei_for_sync(record, patient)
    event_id = referral_event_id_for_sync(record)

    ReferralStatusSyncJob.perform_async(patient_id, tei, event_id)
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue referral status sync for patient #{patient_id}: #{e.class}: #{e.message}")
  end

  def operation_keys_include?(keys)
    (@changed_operation_keys & keys).any?
  end

  def immunization_record?(record)
    program_id = immunization_program_id
    return false if program_id.blank?

    record_value(record, :program_id).to_i == program_id
  end

  def immunization_program_id
    @immunization_program_id ||= Program.find_by(name: 'IMMUNIZATION PROGRAM')&.program_id
  end

  def ncd_record?(patient_id, record)
    return true if record_value(record, :program_id).to_i == NCD_PROGRAM_ID
    return true if record_ncd_enrollment?(record)
    return true if record_ncd_identifier?(record)

    PatientProgram.where(patient_id: patient_id, program_id: NCD_PROGRAM_ID, voided: 0).exists?
  end

  def record_ncd_enrollment?(record)
    Array(record_value(record, :activePrograms)).compact.any? do |enrollment|
      record_value(enrollment, :program_id).to_i == NCD_PROGRAM_ID
    end
  end

  def record_ncd_identifier?(record)
    ncd_id = record_value(record, :NcdID).to_s.strip
    return true if ncd_id.present?

    other_person_information = record_value(record, :otherPersonInformation) || {}
    nested_ncd_id = record_value(other_person_information, :NcdID).to_s.strip
    nested_ncd_id.present?
  end

  def referral_tei_for_sync(record, patient)
    from_record = record_value(record, :TEI).to_s.strip
    return from_record if from_record.present?

    other_person_information = record_value(record, :otherPersonInformation) || {}
    nested_tei = record_value(other_person_information, :TEI).to_s.strip
    return nested_tei if nested_tei.present?

    BuildPatientRecordService.extract_tei(patient).to_s.strip
  end

  def referral_event_id_for_sync(record)
    direct_event_id = record_value(record, :send_ichis_enrolled_in_care_event_id).to_s.strip
    return direct_event_id if direct_event_id.present?

    event_ids = record_value(record, :ichisEventIds) || record_value(record, :ichis_event_ids)
    Array(event_ids).map { |event_id| event_id.to_s.strip }.find(&:present?)
  end

  def record_value(container, key)
    return nil if container.nil? || !container.respond_to?(:[])

    container[key] || container[key.to_s]
  rescue TypeError
    nil
  end
end
