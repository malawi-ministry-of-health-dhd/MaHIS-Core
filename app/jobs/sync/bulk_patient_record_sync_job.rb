# app/jobs/sync/bulk_patient_record_sync_job.rb
module Sync
  class BulkPatientRecordSyncJob < BaseSyncJob
    sidekiq_options queue: :patient_sync, retry: 3
    
    # Sync multiple patient records in one job using CouchDB bulk operations
    def perform(patient_ids, options = {})
      return if patient_ids.blank?

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      patient_ids = patient_ids.uniq

      patient_records = []
      failed_ids = []
      missing_patient_ids = []
      missing_primary_identifier_ids = []
      missing_document_id_ids = []

      existing_patient_ids = Patient.where(patient_id: patient_ids).pluck(:patient_id).to_h { |id| [id, true] }
      identifier_rows = PatientIdentifier.where(patient_id: patient_ids).pluck(:patient_id, :identifier_type, :identifier)
      patient_ids_with_primary_identifier = {}
      identifier_rows.each do |pid, identifier_type, identifier|
        next unless identifier_type == 3
        next if identifier.blank?

        patient_ids_with_primary_identifier[pid] = true
      end
      
      patient_ids.each do |patient_id|
        begin
          unless existing_patient_ids[patient_id]
            missing_patient_ids << patient_id
            failed_ids << patient_id
            next
          end

          unless patient_ids_with_primary_identifier[patient_id]
            missing_primary_identifier_ids << patient_id
            failed_ids << patient_id
            next
          end
          
          patient_record = BuildPatientRecordService.build_patient_record(patient_id)
          unless patient_record
            failed_ids << patient_id
            next
          end

          doc_id = patient_record[:ID] || patient_record.dig(:record, :ID)
          
          if doc_id.present?
            patient_records << patient_record
          else
            missing_document_id_ids << patient_id
            failed_ids << patient_id
          end
        rescue => e
          failed_ids << patient_id
          Sidekiq.logger.error("Failed to build patient record #{patient_id}: #{e.message}")
        end
      end
      
      # Sync all patient records in one bulk operation to CouchDB
      if patient_records.any?
        bulk_sync_patients_to_couchdb(patient_records)
        SyncProgress.increment('patients_records', patient_records.count)

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        records_per_sec = duration.positive? ? (patient_records.count / duration).round(2) : patient_records.count
        Sidekiq.logger.info("Successfully synced #{patient_records.count} patient records in #{duration.round(2)}s (#{records_per_sec} patients/sec)")
      end
      
      if failed_ids.any?
        Sidekiq.logger.warn("Failed to sync #{failed_ids.count} patients: #{failed_ids.first(10).join(', ')}#{failed_ids.count > 10 ? '...' : ''}")
      end

      log_skip_reasons(missing_patient_ids, missing_primary_identifier_ids, missing_document_id_ids)
    end
    
    private

    def log_skip_reasons(missing_patient_ids, missing_primary_identifier_ids, missing_document_id_ids)
      if missing_patient_ids.any?
        Sidekiq.logger.warn("Skipped #{missing_patient_ids.count} patients not found locally: #{missing_patient_ids.first(10).join(', ')}#{missing_patient_ids.count > 10 ? '...' : ''}")
      end

      if missing_primary_identifier_ids.any?
        Sidekiq.logger.warn("Skipped #{missing_primary_identifier_ids.count} patients without identifier_type 3: #{missing_primary_identifier_ids.first(10).join(', ')}#{missing_primary_identifier_ids.count > 10 ? '...' : ''}")
      end

      if missing_document_id_ids.any?
        Sidekiq.logger.warn("Skipped #{missing_document_id_ids.count} patients with empty generated CouchDB _id: #{missing_document_id_ids.first(10).join(', ')}#{missing_document_id_ids.count > 10 ? '...' : ''}")
      end
    end
    
    def bulk_sync_patients_to_couchdb(patient_records)
      db_name = 'patients_records'
      # Skip index management on the write path: with indexes live, CouchDB's
      # background indexer rebuilds all of them after every batch across every
      # parallel job, which saturates CPU and crash-loops the server. Indexes
      # are built once after the fan-out drains (see EnsurePatientIndexesJob).
      ensure_database_exists(db_name, manage_indexes: false)

      # Prepare documents with _id for bulk operation
      documents = patient_records.map do |record|
        prepare_bulk_document(record)
      end

      # Use bulk sync from BaseSyncJob. Skip the up-front _rev fetch: on the
      # initial full load almost nothing exists yet, so posting straight away and
      # resolving the rare conflicts in a second pass halves the CouchDB round
      # trips per batch.
      bulk_result = bulk_sync_to_couchdb(documents, db_name, manage_indexes: false, prefetch_revs: false)
      
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
