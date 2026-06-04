require 'json'
require 'net/http'
require 'rest-client'
require 'uri'
require 'yaml'
require_relative 'couchdb_url'

class FacilityDdeActivationListener
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  FACILITIES_DB_NAME = 'facilities'

  DEFAULT_CONFIG = {
    couchdb_url: CONFIG['COUCHDB_URL'],
    username: CONFIG['COUCHDB_USERNAME'],
    password: CONFIG['COUCHDB_PASSWORD'],
    reconnect_delay: 5,
    timeout: 60_000,
    heartbeat: 30_000
  }.freeze

  attr_reader :config

  def initialize(**options)
    @config = DEFAULT_CONFIG.merge(options)
    validate_configuration!
  end

  def start
    Rails.logger.info('[Facility DDE Listener] Starting facilities CouchDB listener')
    enqueue_if_any_facility_is_activated

    loop do
      listen_to_changes
    rescue RestClient::Exception => e
      Rails.logger.error("[Facility DDE Listener] RestClient error: #{e.message}. Reconnecting in #{config[:reconnect_delay]}s...")
      sleep(config[:reconnect_delay])
    rescue StandardError => e
      Rails.logger.error("[Facility DDE Listener] Unexpected error: #{e.message}. Reconnecting in #{config[:reconnect_delay]}s...")
      Rails.logger.error("[Facility DDE Listener] Error backtrace: #{e.backtrace.first(3).join(' -> ')}") if e.backtrace
      sleep(config[:reconnect_delay])
    end
  end

  private

  def validate_configuration!
    raise ArgumentError, 'couchdb_url is required' if config[:couchdb_url].blank?
  end

  def listen_to_changes
    username, password = couchdb_credentials
    uri = URI(couchdb_url(FACILITIES_DB_NAME, '_changes'))
    uri.query = URI.encode_www_form(
      feed: 'continuous',
      include_docs: true,
      timeout: config[:timeout],
      heartbeat: config[:heartbeat],
      since: 'now'
    )

    Rails.logger.info('[Facility DDE Listener] Connecting to facilities _changes feed')

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri)
      request.basic_auth(username, password) if username && password

      http.request(request) do |response|
        raise "HTTP #{response.code}: #{response.message}" unless response.is_a?(Net::HTTPSuccess)

        process_response_stream(response)
      end
    end
  end

  def process_response_stream(response)
    line_buffer = ''

    response.read_body do |chunk|
      line_buffer += chunk

      while (newline_pos = line_buffer.index("\n"))
        line = line_buffer[0...newline_pos].strip
        line_buffer = line_buffer[newline_pos + 1..]

        next if line.blank?

        begin
          process_change(JSON.parse(line))
        rescue JSON::ParserError => e
          Rails.logger.warn("[Facility DDE Listener] Failed to parse changes line: #{line[0..100]}... Error: #{e.message}")
        end
      end
    end
  end

  def process_change(change)
    return if change['deleted'] == true

    doc = change['doc']
    return unless doc
    return if doc['_id'].to_s.start_with?('_design/')

    unless dde_activated?(doc)
      Rails.logger.debug("[Facility DDE Listener] Ignoring non-activated facility #{doc['_id']}")
      return
    end

    enqueue_dde_ids_sync(doc)
  end

  def enqueue_if_any_facility_is_activated
    username, password = couchdb_credentials
    resource_options = {
      headers: {
        accept: :json,
        content_type: :json
      }
    }
    resource_options[:user] = username if username
    resource_options[:password] = password if password

    query = {
      selector: {
        '$or' => [
          { 'dde_activated' => true },
          { 'dde_activated' => 'true' }
        ]
      },
      limit: 1
    }

    resource = RestClient::Resource.new(couchdb_url(FACILITIES_DB_NAME, '_find'), resource_options)
    response = resource.post(query.to_json)
    docs = JSON.parse(response.body)['docs'] || []

    return if docs.empty?

    Rails.logger.info('[Facility DDE Listener] Found activated facility on startup; queueing DDE IDs sync')
    enqueue_dde_ids_sync(docs.first)
  rescue RestClient::NotFound
    Rails.logger.warn("[Facility DDE Listener] Facilities database '#{FACILITIES_DB_NAME}' not found; startup scan skipped")
  rescue StandardError => e
    Rails.logger.error("[Facility DDE Listener] Failed startup activated-facility scan: #{e.message}")
  end

  def enqueue_dde_ids_sync(doc)
    jid = Sync::DdeIdsSyncJob.perform_async
    facility_label = doc['location_id'] || doc['_id']

    if jid.present?
      Rails.logger.info("[Facility DDE Listener] Queued DDE IDs sync job #{jid} for activated facility #{facility_label}")
    else
      Rails.logger.info("[Facility DDE Listener] DDE IDs sync already queued/running for activated facility #{facility_label}")
    end
  end

  def dde_activated?(doc)
    value = doc['dde_activated']
    value == true || value.to_s.strip.casecmp('true').zero?
  end

  def couchdb_credentials
    CouchdbUrl.credentials(config[:couchdb_url], config[:username], config[:password])
  end

  def couchdb_url(*segments)
    CouchdbUrl.join(config[:couchdb_url], *segments, include_credentials: false)
  end
end
