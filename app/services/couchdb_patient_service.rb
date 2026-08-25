require 'rest-client'
require 'json'
require 'yaml'
require Rails.root.join('lib', 'couchdb_url').to_s

class CouchdbPatientService
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  PATIENTS_DB = 'patients_records'

  class << self
    # Check if CouchDB is configured
    def couchdb_configured?
      COUCHDB_URL.present?
    end

    def ensure_db_exists(db_name = PATIENTS_DB)
      RestClient.put(couchdb_url(db_name), '') if couchdb_configured?
      true
    rescue RestClient::PreconditionFailed
      true # Database already exists
    rescue StandardError => e
      Rails.logger.error "CouchDB error: #{e.message}"
      false
    end

    def couchdb_url(*segments)
      CouchdbUrl.join(COUCHDB_URL, *segments)
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
    rescue StandardError => e
      Rails.logger.error "Error getting patient record: #{e.message}"
      patient_ids.present? ? [] : nil
    end

    def get_latest_encounter_date_changed(db_name = 'patients_records')
      unless couchdb_configured?
        Rails.logger.warn 'CouchDB not configured. Cannot fetch latest encounter date.'
        return nil
      end

      ensure_db_exists(db_name)

      # Create the correct index
      create_encounter_date_index(db_name)

      query = {
        selector: {
          encounter_date_changed: { "$exists": true, "$ne": nil }
        },
        sort: [{ encounter_date_changed: 'desc' }],
        limit: 1,
        use_index: 'encounter_date_changed_simple',
        fields: ['encounter_date_changed']
      }

      response = RestClient.post(
        couchdb_url(db_name, '_find'),
        query.to_json,
        { content_type: :json, accept: :json }
      )

      result = JSON.parse(response.body)

      return nil unless result['docs'].any?

      doc = result['docs'].first
      doc['encounter_date_changed']
    rescue RestClient::ExceptionWithResponse => e
      error_message = "Error querying latest encounter date: #{e.response&.body || e.message}"
      Rails.logger.error error_message
      nil
    rescue StandardError => e
      error_message = "Unexpected error: #{e.message}"
      Rails.logger.error error_message
      nil
    end

    def patient_record_count(db_name = PATIENTS_DB)
      unless couchdb_configured?
        Rails.logger.warn 'CouchDB not configured. Cannot fetch patient record count.'
        return nil
      end

      ensure_db_exists(db_name)

      response = RestClient.get(couchdb_url(db_name))
      db_info = JSON.parse(response.body)
      db_info['doc_count'].to_i - design_doc_count(db_name)
    rescue RestClient::NotFound
      0
    rescue StandardError => e
      Rails.logger.error "Error querying CouchDB patient record count: #{e.message}"
      nil
    end

    def create_encounter_date_index(db_name)
      return unless couchdb_configured?

      # Check if the correct index already exists
      begin
        response = RestClient.get(couchdb_url(db_name, '_index'))
        indexes = JSON.parse(response.body)

        # Look for an index with the correct field structure
        existing_index = indexes['indexes'].find do |idx|
          idx['name'] == 'encounter_date_changed_simple' &&
            idx['def'] &&
            idx['def']['fields'] == ['encounter_date_changed']
        end

        if existing_index
          Rails.logger.info 'Correct index encounter_date_changed_simple already exists'
          return
        end
      rescue StandardError => e
        Rails.logger.warn "Could not check existing indexes: #{e.message}"
      end

      # Create index with ONLY the field name - no sort direction
      index_doc = {
        index: {
          fields: ['encounter_date_changed'], # JUST the field name
          partial_filter_selector: {
            encounter_date_changed: { "$exists": true, "$ne": nil }
          }
        },
        name: 'encounter_date_changed_simple',
        ddoc: 'encounter_date_changed_simple',
        type: 'json'
      }

      response = RestClient.post(
        couchdb_url(db_name, '_index'),
        index_doc.to_json,
        { content_type: :json, accept: :json }
      )

      result = JSON.parse(response.body)
      Rails.logger.info "Index creation result: #{result['result']}"

      # Wait for index to be built
      if result['result'] == 'created'
        Rails.logger.info 'New index encounter_date_changed_simple is ready.'
        sleep(1) # Give CouchDB time to build the index
      end
    rescue RestClient::ExceptionWithResponse => e
      if e.response.code == 409
        Rails.logger.info 'Index already exists - continuing...'
      else
        Rails.logger.error "Error creating index: #{e.response&.body || e.message}"
      end
    rescue StandardError => e
      Rails.logger.error "Unexpected error creating index: #{e.message}"
    end

    # Method to sync from external source to CouchDB
    def sync_patient_to_couchdb(patient_data, patient_id)
      unless couchdb_configured?
        Rails.logger.warn 'CouchDB not configured. Skipping sync.'
        return { success: false, error: 'CouchDB not configured' }
      end

      ensure_db_exists
      save_patient_record(patient_data, patient_id)
      { success: true }
    rescue StandardError => e
      Rails.logger.error "Error syncing patient to CouchDB: #{e.message}"
      { success: false, error: e.message }
    end

    # Utility method for bulk operations
    def bulk_update_patients(patient_records)
      unless couchdb_configured?
        Rails.logger.warn 'CouchDB not configured. Skipping bulk update.'
        return { success: false, error: 'CouchDB not configured' }
      end

      docs = patient_records.map do |record|
        record.merge({
                       'last_sync_at' => Time.current.iso8601,
                       'sync_status' => 'synced'
                     })
      end

      bulk_payload = { docs: docs }.to_json

      response = RestClient.post(
        couchdb_url(PATIENTS_DB, '_bulk_docs'),
        bulk_payload,
        { content_type: :json, accept: :json }
      )

      { success: true, response: JSON.parse(response.body) }
    rescue StandardError => e
      Rails.logger.error "Error in bulk update: #{e.message}"
      { success: false, error: e.message }
    end

    private

    MAX_ART_SUMMARY_REFRESH_ATTEMPTS = 3

    def refresh_art_summary(record, local_patient)
      return record unless record.is_a?(Hash) && local_patient

      art_summary = record['art_summary']
      return record unless art_summary.is_a?(Hash)

      fresh_art_summary = ArtService::PatientSummaryBuilder.new(local_patient.patient_id).build.as_json
      replace_art_summary(local_patient.patient_id, fresh_art_summary) || record
    rescue StandardError => e
      Rails.logger.warn("Could not refresh ART summary for patient #{local_patient&.patient_id}: #{e.class}: #{e.message}")
      record
    end

    # Re-fetches the CouchDB document immediately before writing so the merge
    # is based on the latest revision rather than the (possibly stale) body
    # fetched before the MySQL rebuild ran, and retries on revision conflicts.
    def replace_art_summary(patient_id, fresh_art_summary)
      document_id = PatientRecordIdentityService.document_id(patient: Patient.unscoped.find_by(patient_id:)) || patient_id.to_s

      MAX_ART_SUMMARY_REFRESH_ATTEMPTS.times do
        latest_doc = JSON.parse(RestClient.get(couchdb_url(PATIENTS_DB,
                                                           URI.encode_www_form_component(document_id))).body)
        art_summary = latest_doc['art_summary']
        return latest_doc unless art_summary.is_a?(Hash)
        return latest_doc if art_summary == fresh_art_summary

        latest_doc['art_summary'] = fresh_art_summary

        begin
          save_patient_record(latest_doc, patient_id)
          return latest_doc
        rescue RestClient::Conflict
          next # document changed between our fetch and save; retry with a fresh fetch
        end
      end

      nil
    rescue RestClient::NotFound
      nil
    end

    def design_doc_count(db_name)
      response = RestClient.get(couchdb_url(db_name, '_design_docs'))
      JSON.parse(response.body)['rows'].length
    rescue StandardError
      0
    end

    def get_multiple_patients(patient_ids)
      return false unless couchdb_configured?

      # Resolve numeric MySQL IDs to their permanent CouchDB record IDs. Values
      # that are already document IDs remain unchanged for compatibility.
      resolved = patient_ids.index_with do |value|
        patient = Patient.unscoped.includes(:person).find_by(patient_id: value) if value.to_s.match?(/\A\d+\z/)
        PatientRecordIdentityService.document_id(patient:) || value.to_s
      end
      keys_payload = { keys: resolved.values }.to_json

      response = RestClient.post(
        "#{couchdb_url(PATIENTS_DB, '_all_docs')}?include_docs=true",
        keys_payload,
        { content_type: :json, accept: :json }
      )

      result = JSON.parse(response.body)

      # Extract documents, filter out missing ones
      records = result['rows']
                .reject { |row| row['error'] == 'not_found' }
                .map { |row| row['doc'] }

      # Handle missing patients by creating them
      found_ids = records.map { |doc| doc['patientID'].to_s }
      missing_ids = patient_ids.reject { |value| found_ids.include?(value.to_s) }

      missing_ids.each do |missing_id|
        new_record = build_patient_record(missing_id)
        records << new_record if new_record
      end

      records
    end

    def get_single_patient(patient_id)
      if couchdb_configured?
        local_patient = nil

        begin
          if patient_id.to_s.match?(/\A\d+\z/)
            local_patient = Patient.unscoped.includes(:person).find_by(patient_id: patient_id)
          end
          document_id = PatientRecordIdentityService.document_id(patient: local_patient) || patient_id.to_s
          response = RestClient.get(couchdb_url(PATIENTS_DB, URI.encode_www_form_component(document_id)))
          refresh_art_summary(JSON.parse(response.body), local_patient)
        rescue RestClient::NotFound
          # A numeric ID that resolves to a local patient is not a legacy DDE
          # identifier. On a newly registered patient, searching for it using
          # the legacy-identifier Mango selector causes a full CouchDB scan.
          # Build the missing UUID document directly instead.
          return build_patient_record(patient_id) if local_patient

          by_identifier = find_patient_document_by_identifier(patient_id)
          return by_identifier if by_identifier

          # Patient doesn't exist, build new record
          patient_id.to_s.match?(/\A\d+\z/) ? build_patient_record(patient_id) : nil
        end
      else
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
      end
    rescue StandardError => e
      Rails.logger.error "Failed to build patient record for #{patient_id}: #{e.message}"
      nil
    end

    def save_patient_record(record_data, _patient_id)
      return unless couchdb_configured?

      # Ensure the document has the required CouchDB fields
      document_id = PatientRecordIdentityService.document_id(record: record_data)
      doc_data = record_data.as_json.merge({
                                             '_id' => document_id,
                                             'last_sync_at' => Time.current.iso8601,
                                             'sync_status' => 'synced'
                                           })

      # Check if document exists to get _rev
      begin
        existing_doc = RestClient.get(couchdb_url(PATIENTS_DB, URI.encode_www_form_component(document_id)))
        doc_data['_rev'] = JSON.parse(existing_doc.body)['_rev']
      rescue RestClient::NotFound
        # New document, no _rev needed
      end

      RestClient.put(
        couchdb_url(PATIENTS_DB, URI.encode_www_form_component(document_id)),
        doc_data.to_json,
        { content_type: :json, accept: :json }
      )
    end

    def find_patient_document_by_identifier(identifier)
      response = RestClient.post(
        couchdb_url(PATIENTS_DB, '_find'),
        {
          selector: {
            '$or' => [
              { 'ID' => identifier.to_s },
              { 'legacyDdeID' => identifier.to_s }
            ]
          },
          limit: 1
        }.to_json,
        { content_type: :json, accept: :json }
      )
      JSON.parse(response.body).fetch('docs', []).first
    rescue StandardError
      nil
    end
  end
end
