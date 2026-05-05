require 'rest-client'
require 'json'
require 'yaml'
require_relative 'couchdb_url'

module CouchdbSync
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  MAX_RETRY_ATTEMPTS = 3

  def couchdb_configured?
    COUCHDB_URL.present?
  end

  def skip_couchdb_sync?
    Thread.current['skip_couchdb_sync'] == true || Thread.current[:skip_couchdb_sync] == true
  end

  def ensure_db_exists(db_name)
    RestClient.put(couchdb_url(db_name), '')
  rescue RestClient::PreconditionFailed
    # Database already exists
  end

  def couchdb_url(*segments)
    CouchdbUrl.join(COUCHDB_URL, *segments)
  end

  def sync_to_couchdb(doc_data, db_name, doc_id)
    return unless couchdb_configured?
    return if skip_couchdb_sync?

    ensure_db_exists(db_name)
    encoded_doc_id = URI.encode_www_form_component(doc_id.to_s)
    doc_url = couchdb_url(db_name, encoded_doc_id)

    attempt = 1

    begin
      payload = doc_data.deep_dup

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
    rescue RestClient::Conflict, RestClient::PreconditionFailed
      raise if attempt >= MAX_RETRY_ATTEMPTS

      attempt += 1
      sleep(0.1 * attempt)
      retry
    end
  end
end
