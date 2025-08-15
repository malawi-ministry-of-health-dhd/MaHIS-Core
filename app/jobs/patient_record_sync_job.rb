require 'rest-client'
require 'json'

class PatientRecordSyncJob
  include Sidekiq::Job
  sidekiq_options queue: :patient_sync, retry: 3
  COUCHDB_URL = YAML.safe_load(File.read('config/application.yml'))['COUCHDB_URL']

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

  private

  def ensure_db_exists(db_name)
    begin
      RestClient.put("#{COUCHDB_URL}/#{db_name}", '')
    rescue RestClient::PreconditionFailed
      # Already exists
    end
  end

  def sync_to_couchdb(doc_data, db_name, doc_id)
    ensure_db_exists(db_name)

    # Get _rev if updating
    begin
      existing_doc = RestClient.get("#{COUCHDB_URL}/#{db_name}/#{doc_id}")
      doc_data["_rev"] = JSON.parse(existing_doc.body)["_rev"]
    rescue RestClient::NotFound
      # First insert
    end

    RestClient.put(
      "#{COUCHDB_URL}/#{db_name}/#{doc_id}",
      doc_data.to_json,
      { content_type: :json, accept: :json }
    )
  end
end
