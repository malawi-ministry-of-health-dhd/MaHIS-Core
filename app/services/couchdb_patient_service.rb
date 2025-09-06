require 'rest-client'
require 'json'
require 'yaml'

class CouchdbPatientService
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  PATIENTS_DB = 'patients_records'

  class << self
    def ensure_db_exists(db_name = PATIENTS_DB)
      RestClient.put("#{COUCHDB_URL}/#{db_name}", '')
    rescue RestClient::PreconditionFailed
      # Database already exists
    end

    def get_patient_record(patient_ids: nil, patient_id: nil)
      ensure_db_exists

      if patient_ids.present?
        # Handle multiple patient IDs
        ids = patient_ids.is_a?(String) ? patient_ids.split(',') : patient_ids
        get_multiple_patients(ids)
      elsif patient_id.present?
        # Handle single patient ID
        get_single_patient(patient_id)
      else
        raise ArgumentError, 'Missing patient identifier'
      end
    end

    private

    def get_multiple_patients(patient_ids)
      # Use CouchDB _all_docs endpoint with keys parameter
      keys_payload = { keys: patient_ids }.to_json
      
      response = RestClient.post(
        "#{COUCHDB_URL}/#{PATIENTS_DB}/_all_docs?include_docs=true",
        keys_payload,
        { content_type: :json, accept: :json }
      )

      result = JSON.parse(response.body)
      
      # Extract documents, filter out missing ones
      records = result['rows']
        .reject { |row| row['error'] == 'not_found' }
        .map { |row| row['doc'] }

      # Handle missing patients by creating them
      found_ids = records.map { |doc| doc['patientID'] }
      missing_ids = patient_ids - found_ids
      
      missing_ids.each do |missing_id|
        new_record = build_patient_record(missing_id)
        records << new_record if new_record
      end

      records
    end

    def get_single_patient(patient_id)
      begin
        # Try to fetch existing document
        response = RestClient.get("#{COUCHDB_URL}/#{PATIENTS_DB}/#{patient_id}")
        JSON.parse(response.body)
      rescue RestClient::NotFound
        # Patient doesn't exist, build new record
        build_patient_record(patient_id)
      end
    end

    def build_patient_record(patient_id)
      # This would call your existing BuildPatientRecordService or create a new one
      record_data = BuildPatientRecordService.build_patient_record(patient_id)
      
      # Save to CouchDB if successfully built
      if record_data
        save_patient_record(record_data, patient_id)
        record_data
      else
        nil
      end
    rescue => e
      Rails.logger.error "Failed to build patient record for #{patient_id}: #{e.message}"
      nil
    end

    def save_patient_record(record_data, patient_id)
      # Ensure the document has the required CouchDB fields
      doc_data = record_data.as_json.merge({
        '_id' => patient_id,
        'patientID' => patient_id,
        'ID' => patient_id,
        'last_sync_at' => Time.current.iso8601,
        'sync_status' => 'synced'
      })

      # Check if document exists to get _rev
      begin
        existing_doc = RestClient.get("#{COUCHDB_URL}/#{PATIENTS_DB}/#{patient_id}")
        doc_data['_rev'] = JSON.parse(existing_doc.body)['_rev']
      rescue RestClient::NotFound
        # New document, no _rev needed
      end

      RestClient.put(
        "#{COUCHDB_URL}/#{PATIENTS_DB}/#{patient_id}",
        doc_data.to_json,
        { content_type: :json, accept: :json }
      )
    end

    # Utility method for bulk operations
    def bulk_update_patients(patient_records)
      docs = patient_records.map do |record|
        record.merge({
          'last_sync_at' => Time.current.iso8601,
          'sync_status' => 'synced'
        })
      end

      bulk_payload = { docs: docs }.to_json

      RestClient.post(
        "#{COUCHDB_URL}/#{PATIENTS_DB}/_bulk_docs",
        bulk_payload,
        { content_type: :json, accept: :json }
      )
    end

    # Method to sync from external source to CouchDB
    def sync_patient_to_couchdb(patient_data, patient_id)
      ensure_db_exists
      save_patient_record(patient_data, patient_id)
    end
  end
end