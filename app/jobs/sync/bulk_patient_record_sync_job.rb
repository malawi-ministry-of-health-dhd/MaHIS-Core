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
      missing_document_id_ids = []

      existing_patient_ids = Patient.where(patient_id: patient_ids).pluck(:patient_id).to_h { |id| [id, true] }
      assignment_states = PatientRecordIdentityService.assignment_states(patient_ids)
      
      patient_ids.each do |patient_id|
        begin
          unless existing_patient_ids[patient_id]
            missing_patient_ids << patient_id
            failed_ids << patient_id
            next
          end

          patient_record = BuildPatientRecordService.build_patient_record(
            patient_id,
            dde_assignment: assignment_states[patient_id.to_i]
          )
          unless patient_record
            failed_ids << patient_id
            next
          end

          doc_id = PatientRecordIdentityService.document_id(record: patient_record)
          
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
      
      # Sync all patient records in one bulk operation to CouchDB. Progress for
      # 'patients_records' is tracked from CouchDB's actual doc count by
      # EnsurePatientIndexesJob (not per-batch increments), so a re-sync of
      # already-present patients can't push the count past the real total.
      bulk_errors = []
      if patient_records.any?
        bulk_result = bulk_sync_patients_to_couchdb(patient_records)
        bulk_errors = bulk_result[:errors]
        retire_legacy_npid_documents(patient_records) if bulk_errors.empty?

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        records_per_sec = duration.positive? ? (patient_records.count / duration).round(2) : patient_records.count
        if bulk_errors.empty?
          Sidekiq.logger.info("Successfully synced #{patient_records.count} patient records in #{duration.round(2)}s (#{records_per_sec} patients/sec)")
        end
      end
      
      if failed_ids.any?
        Sidekiq.logger.warn("Failed to sync #{failed_ids.count} patients: #{failed_ids.first(10).join(', ')}#{failed_ids.count > 10 ? '...' : ''}")
      end

      log_skip_reasons(missing_patient_ids, missing_document_id_ids)

      return if failed_ids.empty? && bulk_errors.empty?

      # Every patient should have a durable person UUID. A missing document ID
      # is therefore a retryable data-integrity failure, not an NPID omission.
      raise "Patient CouchDB bulk sync incomplete: failed_patients=#{failed_ids.size}, " \
            "couchdb_errors=#{bulk_errors.size}"
    end
    
    private

    def log_skip_reasons(missing_patient_ids, missing_document_id_ids)
      if missing_patient_ids.any?
        Sidekiq.logger.warn("Skipped #{missing_patient_ids.count} patients not found locally: #{missing_patient_ids.first(10).join(', ')}#{missing_patient_ids.count > 10 ? '...' : ''}")
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

      bulk_result
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
      PatientRecordIdentityService.document_id(record: patient_record)
    end

    def retire_legacy_npid_documents(patient_records)
      patient_records.each do |record|
        patient_id = (record[:patientID] || record['patientID']).to_i
        document_id = generate_document_id(record)
        candidates = [
          record[:ID], record['ID'], record[:legacyDdeID], record['legacyDdeID'],
          *Array.wrap(record[:legacyDdeIDs]), *Array.wrap(record['legacyDdeIDs']),
          ("patient:#{document_id}" if document_id.present?)
        ]
                     .map { |value| value.to_s.strip }.reject(&:blank?).uniq

        candidates.each do |candidate|
          next if candidate == document_id

          legacy_doc = fetch_couchdb_doc('patients_records', candidate)
          next unless legacy_doc
          next unless (legacy_doc['patientID'] || legacy_doc['patient_id']).to_i == patient_id

          delete_from_couchdb('patients_records', candidate)
          Sidekiq.logger.info("Retired legacy NPID-keyed CouchDB document #{candidate} for patient #{patient_id}")
        end
      rescue StandardError => e
        Sidekiq.logger.warn("Could not retire legacy CouchDB document for patient #{patient_id}: #{e.class}: #{e.message}")
      end
    end
  end
end

# Usage examples:
# Sync::BulkPatientRecordSyncJob.perform_async([12345, 12346, 12347], { 'location_id' => 700 })
