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

  # Persisted _changes checkpoint (a CouchDB _local doc, the standard pattern)
  # so a restart resumes from the exact sequence and replays activations missed
  # while the listener was down, instead of starting from 'now' and losing them.
  CHECKPOINT_DOC_ID = '_local/facility_dde_activation_listener'
  CHECKPOINT_INTERVAL = 10 # seconds between checkpoint writes (debounce)

  attr_reader :config

  def initialize(**options)
    @config = DEFAULT_CONFIG.merge(options)
    @last_sequence = nil
    @checkpoint_rev = nil
    @last_checkpoint_at = nil
    validate_configuration!
  end

  def start
    Rails.logger.info('[Facility DDE Listener] Starting facilities CouchDB listener')

    @last_sequence = load_checkpoint
    if @last_sequence.present?
      Rails.logger.info('[Facility DDE Listener] Resuming facilities _changes from saved checkpoint (replays activations missed while down)')
    else
      Rails.logger.info('[Facility DDE Listener] No saved checkpoint; scanning current activations and starting from now')
      enqueue_if_any_facility_is_activated
      @last_sequence = 'now'
    end

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
      since: @last_sequence || 'now'
    )

    Rails.logger.info("[Facility DDE Listener] Connecting to facilities _changes feed: #{uri}")

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri)
      request.basic_auth(username, password) if username && password

      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          # A stale/invalid saved sequence (e.g. the facilities DB was recreated)
          # makes CouchDB return 400. Reset to 'now' + rescan rather than looping.
          if response.code.to_i == 400 && @last_sequence != 'now'
            Rails.logger.warn("[Facility DDE Listener] _changes rejected saved sequence (HTTP #{response.code}); resetting to 'now' and rescanning")
            reset_checkpoint_and_rescan
            return
          end

          raise "HTTP #{response.code}: #{response.message}"
        end

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
    if change['seq'].present?
      @last_sequence = change['seq']
      save_checkpoint(@last_sequence)
    end
    return if change['deleted'] == true

    doc = change['doc']
    return unless doc
    return if doc['_id'].to_s.start_with?('_design/')

    unless dde_activated?(doc)
      Rails.logger.debug("[Facility DDE Listener] Ignoring non-activated facility #{doc['_id']}")
      return
    end

    Rails.logger.info("[Facility DDE Listener] Activated facility change detected: #{facility_location_id(doc) || doc['_id']}")
    enqueue_dde_ids_sync(doc)
  end

  def enqueue_if_any_facility_is_activated
    username, password = couchdb_credentials
    uri = URI(couchdb_url(FACILITIES_DB_NAME, '_all_docs'))
    uri.query = URI.encode_www_form(include_docs: true)
    request = RestClient::Request.new(
      method: :get,
      url: uri.to_s,
      headers: { accept: :json },
      user: username,
      password: password
    )
    response = request.execute
    rows = JSON.parse(response.body)['rows'] || []
    docs = rows.filter_map do |row|
      doc = row['doc']
      next unless doc
      next if doc['_id'].to_s.start_with?('_design/')

      doc if dde_activated?(doc)
    end

    return if docs.empty?

    Rails.logger.info('[Facility DDE Listener] Found activated facility on startup; queueing DDE IDs sync for all active facilities')
    enqueue_all_dde_ids_sync
  rescue RestClient::NotFound
    Rails.logger.warn("[Facility DDE Listener] Facilities database '#{FACILITIES_DB_NAME}' not found; startup scan skipped")
  rescue StandardError => e
    Rails.logger.error("[Facility DDE Listener] Failed startup activated-facility scan: #{e.message}")
  end

  def enqueue_dde_ids_sync(doc)
    facility_label = facility_location_id(doc)
    unless facility_label.present?
      Rails.logger.warn("[Facility DDE Listener] Activated facility #{doc['_id']} has no location_id; DDE IDs sync was not queued")
      return
    end

    jid = enqueue_dde_ids_sync_job(100, facility_label.to_s)

    if jid.present?
      Rails.logger.info("[Facility DDE Listener] Queued DDE IDs sync job #{jid} for activated facility #{facility_label}")
    else
      Rails.logger.info("[Facility DDE Listener] DDE IDs sync already queued/running for activated facility #{facility_label}")
    end
  end

  def enqueue_all_dde_ids_sync
    jid = enqueue_dde_ids_sync_job(100, nil)

    if jid.present?
      Rails.logger.info("[Facility DDE Listener] Queued DDE IDs sync job #{jid} for all activated facilities")
    else
      Rails.logger.info('[Facility DDE Listener] DDE IDs sync already queued/running for all activated facilities')
    end
  end

  def enqueue_dde_ids_sync_job(batch_size, location_id)
    Rails.logger.info("[Facility DDE Listener] Enqueueing Sync::DdeIdsSyncJob on #{Sync::DdeIdsSyncJob.get_sidekiq_options['queue']} with args [#{batch_size.inspect}, #{location_id.inspect}]")
    Sync::DdeIdsSyncJob.perform_async(batch_size, location_id)
  rescue StandardError => e
    Rails.logger.error("[Facility DDE Listener] Failed to enqueue Sync::DdeIdsSyncJob: #{e.class}: #{e.message}")
    Rails.logger.error("[Facility DDE Listener] Enqueue backtrace: #{e.backtrace.first(3).join(' -> ')}") if e.backtrace
    nil
  end

  def facility_location_id(doc)
    doc['location_id'].presence || doc['_id'].to_s[/\Afacility_(.+)\z/, 1]
  end

  def dde_activated?(doc)
    value = doc['dde_activated']
    value == true || value.to_s.strip.casecmp('true').zero?
  end

  # Read the saved _changes sequence from the _local checkpoint doc. Returns nil
  # on first run (no checkpoint) so the caller falls back to the startup scan.
  def load_checkpoint
    data = JSON.parse(checkpoint_resource.get.body)
    @checkpoint_rev = data['_rev']
    data['since'].presence
  rescue RestClient::NotFound
    @checkpoint_rev = nil
    nil
  rescue StandardError => e
    Rails.logger.warn("[Facility DDE Listener] Could not load sequence checkpoint: #{e.message}")
    nil
  end

  # Persist the latest sequence, debounced (activations are rare and re-reading
  # the last few seconds of changes after a crash is harmless — DDE sync jobs are
  # idempotent/deduped). 'now' is never persisted; it's not a resumable sequence.
  def save_checkpoint(seq, force: false)
    return if seq.blank? || seq == 'now'
    return if !force && @last_checkpoint_at && (monotonic - @last_checkpoint_at) < CHECKPOINT_INTERVAL

    body = { 'since' => seq }
    body['_rev'] = @checkpoint_rev if @checkpoint_rev
    response = checkpoint_resource.put(body.to_json)
    @checkpoint_rev = JSON.parse(response.body)['rev']
    @last_checkpoint_at = monotonic
  rescue RestClient::Conflict
    load_checkpoint # refresh _rev; the next change will retry the save
  rescue StandardError => e
    Rails.logger.warn("[Facility DDE Listener] Could not save sequence checkpoint (seq=#{seq}): #{e.message}")
  end

  def reset_checkpoint_and_rescan
    @last_sequence = 'now'
    @checkpoint_rev = nil
    enqueue_if_any_facility_is_activated
  end

  def checkpoint_resource
    username, password = couchdb_credentials
    options = { headers: { content_type: :json, accept: :json } }
    options[:user] = username if username
    options[:password] = password if password
    RestClient::Resource.new(couchdb_url(FACILITIES_DB_NAME, CHECKPOINT_DOC_ID), options)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def couchdb_credentials
    CouchdbUrl.credentials(config[:couchdb_url], config[:username], config[:password])
  end

  def couchdb_url(*segments)
    CouchdbUrl.join(config[:couchdb_url], *segments, include_credentials: false)
  end
end
