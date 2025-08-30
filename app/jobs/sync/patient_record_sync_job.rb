# app/jobs/sync/patient_record_sync_job.rb
module Sync
  class PatientRecordSyncJob < BaseSyncJob
    sidekiq_options queue: :patient_sync, retry: 3
    
    # Sync a single patient record to CouchDB
    def perform(patient_id, options = {})
      return unless Patient.exists?(patient_id: patient_id)
      
      patient_record = BuildPatientRecordService.build_patient_record(patient_id)
      doc_id = patient_record[:ID] || patient_record.dig(:record, :ID)
      
      raise "Missing patient ID for CouchDB sync" if doc_id.blank?
      
      # Use the base class sync method
      sync_record_to_couchdb(patient_record, 'patients_records')
      
      Sidekiq.logger.info("Successfully synced patient record #{patient_id}")
    end
    
    private
    
    def prepare_document(patient_record)
      patient_record.merge(
        "last_sync_at" => Time.current.iso8601
      )
    end
    
    def generate_document_id(patient_record)
      patient_record[:ID] || patient_record.dig(:record, :ID)
    end
  end
end

# Usage examples:
# Single patient sync:
# Sync::PatientRecordSyncJob.perform_async(12345, { 'location_id' => 700 })

