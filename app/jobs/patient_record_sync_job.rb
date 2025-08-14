require 'rest-client'
require 'json'

class PatientRecordSyncJob
  include Sidekiq::Job
  sidekiq_options queue: :patient_sync, retry: 3

  def perform(patient_id, options = {})
    location_id = options['location_id']
    patient_record = PatientRecord.find_or_initialize_by(patient_id: patient_id)

    Rails.logger.info("Starting sync for patient #{patient_id}")

    patient_data = safely_build_patient_record(patient_id)
    if patient_data.nil?
      Rails.logger.error("Failed to build data for patient #{patient_id}")
      patient_record.update(sync_status: 'failed', last_sync_at: Time.current)
      return
    end

    # Save to MongoDB
    patient_record.record = patient_data
    patient_record.encounter_datetime = patient_data[:encounter_datetime] if patient_data[:encounter_datetime]
    patient_record.last_sync_at = Time.current
    patient_record.sync_status = 'synced'
    patient_record.save!

    # Sync to CouchDB
    begin
      sync_to_couchdb(patient_record)
    rescue => e
      Rails.logger.error("CouchDB sync failed for patient #{patient_id}: #{e.message}")
    end

    Rails.logger.info("Successfully synced patient record #{patient_id}")
  rescue => e
    patient_record&.update(sync_status: 'failed', last_sync_at: Time.current)
    Rails.logger.error("Error syncing patient record #{patient_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end

  private

  def sync_to_couchdb(patient_record)
    couch_url = 'http://admin:root@localhost:5984'
    db_name   = 'patients_records'
    doc_id    = patient_record.record[:ID]

    doc_data = patient_record.record.merge(
      "_id" => doc_id,
      "last_sync_at" => Time.current.iso8601
    )

    # Get _rev if updating existing doc
    begin
      existing_doc = RestClient.get("#{couch_url}/#{db_name}/#{doc_id}")
      rev = JSON.parse(existing_doc.body)["_rev"]
      doc_data["_rev"] = rev
    rescue RestClient::NotFound
      # First insert, no _rev needed
    end

    RestClient.put(
      "#{couch_url}/#{db_name}/#{doc_id}",
      doc_data.to_json,
      { content_type: :json, accept: :json }
    )
  end

  def safely_build_patient_record(patient_id)
    return nil unless Patient.where(patient_id: patient_id).exists?

    raw_data = BuildPatientRecordService.build_patient_record(patient_id)
    sanitize_for_mongodb(raw_data)
  rescue => e
    Rails.logger.error("Error building patient record #{patient_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  def sanitize_for_mongodb(data)
    case data
    when Hash
      data.each_with_object({}) do |(k, v), h|
        h[k] = sanitize_for_mongodb(v) unless v.nil?
      end
    when Array
      data.map { |item| sanitize_for_mongodb(item) }.compact
    when ActiveRecord::Base
      data.as_json
    when ActiveRecord::Associations::CollectionProxy
      data.map(&:as_json).compact
    when Date, DateTime, Time
      data.iso8601
    when Symbol
      data.to_s
    when Numeric, String, true, false
      data
    else
      data.to_s
    end
  rescue => e
    Rails.logger.error("Error sanitizing value #{data.class.name}: #{e.message}")
    nil
  end
end
