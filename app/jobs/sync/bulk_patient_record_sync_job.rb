# app/jobs/sync/bulk_patient_record_sync_job.rb
module Sync
  class BulkPatientRecordSyncJob < BaseSyncJob
    sidekiq_options queue: :patient_sync, retry: 3
    
    # Sync multiple patient records in one job using CouchDB bulk operations
    def perform(patient_ids, options = {})
      return if patient_ids.blank?
      
      start_time = Time.now
      Sidekiq.logger.info("Starting bulk sync for #{patient_ids.count} patients")
      
      # Build all patient records
      patient_records = []
      failed_ids = []
      
      patient_ids.each do |patient_id|
        begin
          next unless Patient.exists?(patient_id: patient_id)
          
          patient_record = BuildPatientRecordService.build_patient_record(patient_id)
          doc_id = patient_record[:ID] || patient_record.dig(:record, :ID)
          
          if doc_id.present?
            patient_records << patient_record
          else
            failed_ids << patient_id
            Sidekiq.logger.warn("Missing patient ID for patient #{patient_id}")
          end
        rescue => e
          failed_ids << patient_id
          Sidekiq.logger.error("Failed to build patient record #{patient_id}: #{e.message}")
        end
      end
      
      # Sync all patient records in one bulk operation to CouchDB
      if patient_records.any?
        bulk_sync_patients_to_couchdb(patient_records)
        
        duration = Time.now - start_time
        records_per_sec = (patient_records.count / duration).round(2)
        Sidekiq.logger.info("Successfully synced #{patient_records.count} patient records in #{duration.round(2)}s (#{records_per_sec} patients/sec)")
      end
      
      if failed_ids.any?
        Sidekiq.logger.warn("Failed to sync #{failed_ids.count} patients: #{failed_ids.first(10).join(', ')}#{failed_ids.count > 10 ? '...' : ''}")
      end
    end
    
    private
    
    def bulk_sync_patients_to_couchdb(patient_records)
      db_name = 'patients_records'
      ensure_database_exists(db_name)
      
      # Prepare documents with _id for bulk operation
      documents = patient_records.map do |record|
        prepare_bulk_document(record)
      end
      
      # Use bulk sync from BaseSyncJob
      bulk_result = bulk_sync_to_couchdb(documents, db_name)
      
      if bulk_result[:errors].any?
        Sidekiq.logger.error("Bulk sync had #{bulk_result[:errors].length} errors")
        bulk_result[:errors].first(5).each do |error|
          Sidekiq.logger.error("  #{error}")
        end
      end
    end
    
    def prepare_document(patient_record)
      patient_record.merge(
        "synced_at" => Time.current.iso8601
      )
    end
    
    def prepare_bulk_document(patient_record)
      doc = prepare_document(patient_record)
      doc_id = generate_document_id(patient_record)
      doc.merge("_id" => doc_id)
    end
    
    def generate_document_id(patient_record)
      patient_record[:ID] || patient_record.dig(:record, :ID)
    end
  end
end

# Usage examples:
# Sync::BulkPatientRecordSyncJob.perform_async([12345, 12346, 12347], { 'location_id' => 700 })
