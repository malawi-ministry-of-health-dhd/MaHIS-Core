# frozen_string_literal: true

# Finalizes the lifecycle of a DDE ID after the backend has successfully
# created the patient. The browser/local CouchDB remains pull-only; this service
# writes the authoritative state to central CouchDB for replication back down.
class DdeIdPoolService
  include CouchdbSync

  DB_NAME = 'dde'

  def consume!(npid:, location_id:, patient_id:)
    npid = npid.to_s.strip
    location_id = location_id.to_s.strip
    return false if npid.blank? || location_id.blank? || !couchdb_configured?

    ensure_db_exists(DB_NAME)
    update_consumed_document(npid, location_id, patient_id)
  rescue StandardError => e
    Rails.logger.warn("Could not mark DDE ID #{npid} used: #{e.message}")
    false
  end

  private

  def update_consumed_document(npid, location_id, patient_id, attempt = 1)
    document = fetch_pool_document(npid, location_id) || new_used_document(npid, location_id)
    document_url = couchdb_url(DB_NAME, URI.encode_www_form_component(document.fetch('_id')))
    used_at = Time.current.iso8601

    response = RestClient.put(
      document_url,
      document.merge(
        'assigned' => true,
        'allocated' => true,
        'status' => 'used',
        'patient_id' => patient_id,
        'assignedAt' => document['assignedAt'].presence || used_at,
        'usedAt' => used_at
      ).to_json,
      { content_type: :json, accept: :json }
    )
    response.code.between?(200, 299)
  rescue RestClient::Conflict, RestClient::PreconditionFailed
    raise if attempt >= CouchdbSync::MAX_RETRY_ATTEMPTS

    update_consumed_document(npid, location_id, patient_id, attempt + 1)
  end

  def fetch_pool_document(npid, location_id)
    exact_id = "dde_id_#{location_id}_#{npid}"
    response = RestClient.get(couchdb_url(DB_NAME, URI.encode_www_form_component(exact_id)))
    JSON.parse(response.body)
  rescue RestClient::NotFound
    find_pool_document(npid, location_id)
  end

  def find_pool_document(npid, location_id)
    response = RestClient.post(
      couchdb_url(DB_NAME, '_find'),
      {
        selector: {
          npid: npid,
          location_id: location_id
        },
        limit: 1
      }.to_json,
      { content_type: :json, accept: :json }
    )
    JSON.parse(response.body).fetch('docs', []).first
  rescue RestClient::NotFound
    nil
  end

  def new_used_document(npid, location_id)
    {
      '_id' => "dde_id_#{location_id}_#{npid}",
      'dde_id' => npid,
      'dde_location_id' => CouchdbSync::CONFIG['DDE_LOCATION_ID'],
      'location_id' => location_id,
      'npid' => npid,
      'assigned' => true,
      'allocated' => true,
      'status' => 'used',
      'reservation_source' => 'patient_backend'
    }
  end
end
