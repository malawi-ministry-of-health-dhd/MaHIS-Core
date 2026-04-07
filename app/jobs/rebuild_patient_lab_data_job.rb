# frozen_string_literal: true

# Background job to rebuild patient lab data in response to lab events
# This job is triggered by ActiveSupport::Notifications from the his_emr_api_lab gem
class RebuildPatientLabDataJob < ApplicationJob
  include CouchdbSync
  
  queue_as :patient_records

  # Retry with exponential backoff on failures
  retry_on StandardError, wait: :exponentially_longer, attempts: 5

  def perform(patient_id, trigger:, metadata: {})
    Rails.logger.info("RebuildPatientLabDataJob: Starting rebuild for patient #{patient_id} - Trigger: #{trigger}")
    Rails.logger.debug("RebuildPatientLabDataJob: Metadata: #{metadata.inspect}")

    start_time = Time.current

    begin
      # Step 1: Rebuild lab orders data
      lab_orders_data = BuildPatientRecordService.build_lab_orders_data(patient_id)
      Rails.logger.debug("RebuildPatientLabDataJob: Lab orders rebuilt - #{lab_orders_data[:saved]&.count || 0} orders")

      # Step 2: Get encounter type IDs
      lab_orders_type_id = EncounterType.find_by_name('LAB ORDERS')&.encounter_type_id
      lab_results_type_id = EncounterType.find_by_name('LAB RESULTS')&.encounter_type_id

      # Step 3: Rebuild observations for lab encounters
      encounter_types = [lab_orders_type_id, lab_results_type_id].compact
      if encounter_types.any?
        observations = BuildPatientRecordService.build_all_observations(patient_id, encounter_types)
        Rails.logger.debug("RebuildPatientLabDataJob: Observations rebuilt - #{observations&.count || 0} observations")
      end

      # Step 4: Rebuild complete patient record
      patient_record = BuildPatientRecordService.build_patient_record(patient_id)
      
      unless patient_record
        Rails.logger.warn("RebuildPatientLabDataJob: No patient record found for patient #{patient_id}")
        return
      end

      # Step 5: Sync to CouchDB if configured
      if couchdb_configured?
        patient_record["_id"] = patient_record["ID"]
        sync_to_couchdb(patient_record, "patients_records", patient_record["ID"])
        Rails.logger.info("RebuildPatientLabDataJob: Synced to CouchDB for patient #{patient_id}")
      end

      duration = (Time.current - start_time).round(3)
      Rails.logger.info("RebuildPatientLabDataJob: Successfully completed for patient #{patient_id} in #{duration}s")

      # Optional: Track rebuild event for analytics/auditing
      track_rebuild_event(patient_id, trigger, metadata, duration)

    rescue StandardError => e
      Rails.logger.error("RebuildPatientLabDataJob: Failed for patient #{patient_id}: #{e.message}")
      Rails.logger.error("RebuildPatientLabDataJob: Backtrace - #{e.backtrace.first(10).join("\n")}")
      
      # Re-raise to trigger retry mechanism
      raise
    end
  end

  private

  def couchdb_configured?
    # Check if CouchDB is configured and available
    return false unless defined?(CouchdbSync)
    return false unless ENV['COUCHDB_URL'].present? || ENV['couchdb_url'].present?
    
    true
  rescue StandardError => e
    Rails.logger.error("RebuildPatientLabDataJob: CouchDB configuration check failed: #{e.message}")
    false
  end

  def track_rebuild_event(patient_id, trigger, _metadata, duration)
    # Optional: Store rebuild events for analytics or auditing
    # This could write to a separate audit table or analytics system
    Rails.logger.info(
      "RebuildPatientLabDataJob: Event tracked - " \
      "Patient: #{patient_id}, Trigger: #{trigger}, Duration: #{duration}s"
    )
  rescue StandardError => e
    # Don't fail the job if event tracking fails
    Rails.logger.warn("RebuildPatientLabDataJob: Failed to track event: #{e.message}")
  end
end
