require 'rest-client'
require 'json'
require 'yaml'
require_relative 'couchdb_url'

module CouchdbSync
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  MAX_RETRY_ATTEMPTS = 3

  # Dropped/timed-out connections rather than real HTTP failures. CouchDB is hit
  # once per document write, so a busy server resets some of those connections.
  TRANSIENT_CONNECTION_ERRORS = [
    Errno::ECONNRESET,
    Errno::EPIPE,
    EOFError,
    RestClient::Exceptions::Timeout
  ].freeze

  def couchdb_configured?
    COUCHDB_URL.present?
  end

  def skip_couchdb_sync?
    Thread.current['skip_couchdb_sync'] == true || Thread.current[:skip_couchdb_sync] == true
  end

  def ensure_db_exists(db_name)
    attempt = 1

    begin
      RestClient.put(couchdb_url(db_name), '')
      true
    rescue RestClient::PreconditionFailed
      # Database already exists
      false
    rescue *TRANSIENT_CONNECTION_ERRORS => e
      # A reset here used to abort the whole request (e.g. save_patient_record
      # 500ing with "Connection reset by peer") even though the database almost
      # always already exists. Retry the way the document write below does.
      raise if attempt >= MAX_RETRY_ATTEMPTS

      Rails.logger.warn("CouchDB ensure_db_exists(#{db_name}) attempt #{attempt} failed: #{e.class}: #{e.message}")
      attempt += 1
      sleep(0.1 * attempt)
      retry
    end
  end

  def couchdb_url(*segments)
    CouchdbUrl.join(COUCHDB_URL, *segments)
  end

  def sync_to_couchdb(doc_data, db_name, doc_id)
    return unless couchdb_configured?
    return if skip_couchdb_sync?

    created = ensure_db_exists(db_name)
    db_url = couchdb_url(db_name)
    PatientRecordSearchFields.ensure_couchdb_indexes!(db_url, logger: Rails.logger, force: created) if db_name.to_s == PatientRecordSearchFields::PATIENT_RECORD_DB
    ReferenceDataSearchFields.ensure_couchdb_indexes!(db_url, db_name, logger: Rails.logger, force: created)

    encoded_doc_id = URI.encode_www_form_component(doc_id.to_s)
    doc_url = couchdb_url(db_name, encoded_doc_id)

    attempt = 1

    begin
      payload = doc_data.deep_dup
      PatientRecordSearchFields.normalize_if_patient_record!(payload, db_name)
      ReferenceDataSearchFields.normalize_if_supported!(payload, db_name)

      # If updating, fetch latest _rev.
      begin
        existing_doc = RestClient.get(doc_url)
        payload["_rev"] = JSON.parse(existing_doc.body)["_rev"]
      rescue RestClient::NotFound
        # First insert
      end

      RestClient.put(
        doc_url,
        payload.to_json,
        { content_type: :json, accept: :json }
      )
    rescue RestClient::Conflict, RestClient::PreconditionFailed, *TRANSIENT_CONNECTION_ERRORS
      raise if attempt >= MAX_RETRY_ATTEMPTS

      attempt += 1
      sleep(0.1 * attempt)
      retry
    end
  end

  # Fetch a single document by id. Returns the parsed Hash (including _rev/_id)
  # or nil when the document or CouchDB itself is absent. Transient connection
  # resets are retried like the write path.
  def fetch_couchdb_doc(db_name, doc_id)
    return nil unless couchdb_configured?
    return nil if doc_id.to_s.empty?

    encoded_doc_id = URI.encode_www_form_component(doc_id.to_s)
    doc_url = couchdb_url(db_name, encoded_doc_id)

    attempt = 1
    begin
      JSON.parse(RestClient.get(doc_url).body)
    rescue RestClient::NotFound
      nil
    rescue *TRANSIENT_CONNECTION_ERRORS => e
      raise if attempt >= MAX_RETRY_ATTEMPTS

      Rails.logger.warn("CouchDB fetch_couchdb_doc(#{db_name}/#{doc_id}) attempt #{attempt} failed: #{e.class}: #{e.message}")
      attempt += 1
      sleep(0.1 * attempt)
      retry
    end
  end
end
