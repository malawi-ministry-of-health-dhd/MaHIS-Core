class PatientRecordSyncJob
  include Sidekiq::Job
  include CouchdbSync

  sidekiq_options queue: :patient_sync, retry: 3

  def perform(patient_id, options = {})
    return unless Patient.exists?(patient_id: patient_id)

    patient_record = BuildPatientRecordService.build_patient_record(patient_id)
    doc_id = patient_record[:ID] || patient_record.dig(:record, :ID)
    raise "Missing patient ID for CouchDB sync" if doc_id.blank?

    doc_data = patient_record.merge(
      "_id" => doc_id,
      "last_sync_at" => Time.current.iso8601
    )

    sync_to_couchdb(doc_data, 'patients_records', doc_id)
    Rails.logger.info("Successfully synced patient record #{patient_id}")

  rescue RestClient::ExceptionWithResponse => e
    Rails.logger.error("CouchDB sync failed for patient #{patient_id}: #{e.response}")
  rescue => e
    Rails.logger.error("Error syncing patient record #{patient_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
end
