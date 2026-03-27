require 'rest-client'
require 'json'
require 'yaml'

module CouchdbSync
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']

  def couchdb_configured?
    COUCHDB_URL.present?
  end

  def ensure_db_exists(db_name)
    RestClient.put("#{COUCHDB_URL}/#{db_name}", '')
  rescue RestClient::PreconditionFailed
    # Database already exists
  end

  def sync_to_couchdb(doc_data, db_name, doc_id)
    return if Thread.current['skip_couchdb_sync']
    return unless couchdb_configured?

    ensure_db_exists(db_name)

    attempts = 0
    begin
      attempts += 1

      # If updating, fetch _rev
      begin
        existing_doc = RestClient.get("#{COUCHDB_URL}/#{db_name}/#{doc_id}")
        doc_data["_rev"] = JSON.parse(existing_doc.body)["_rev"]
      rescue RestClient::NotFound
        doc_data.delete("_rev")
      end

      RestClient.put(
        "#{COUCHDB_URL}/#{db_name}/#{doc_id}",
        doc_data.to_json,
        { content_type: :json, accept: :json }
      )
    rescue RestClient::Conflict, RestClient::PreconditionFailed => e
      raise e if attempts >= 3

      sleep(0.1 * attempts)
      retry
    end
  end
end
