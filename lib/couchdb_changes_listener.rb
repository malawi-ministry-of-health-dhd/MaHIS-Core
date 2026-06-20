require 'rest-client'
require 'json'
require 'yaml'
require_relative 'couchdb_url'

class CouchdbChangesListener
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  
  DEFAULT_CONFIG = {
    couchdb_url: CONFIG['COUCHDB_URL'],
    username: CONFIG['COUCHDB_USERNAME'],
    password: CONFIG['COUCHDB_PASSWORD'],
    reconnect_delay: 5,
    max_retry_attempts: 3,
    batch_size: 100,
    backfill_scan_page_size: 1000,
    timeout: 60000,
    heartbeat: 30000,
    # When true the listener is a thin dispatcher: it enqueues a Sync::CouchIngestJob
    # per change (live feed + backfill) instead of processing inline. Preferred on
    # TiDB, where concurrency beats single-threaded latency. Default false keeps the
    # existing inline behaviour, so this is an opt-in, drop-in change.
    fan_out: false
  }.freeze

  # db_name => [processor service class name, method]. Single source of truth used
  # by both the dispatcher (rake) and the fan-out worker (Sync::CouchIngestJob).
  PROCESSORS = {
    'patients_records' => ['SavePatientRecordService', :create_patient_record],
    'visits'           => ['VisitService', :create_update_visit],
    'stages'           => ['StagesService', :create_stage]
  }.freeze

  attr_reader :db_name, :config, :processor_service, :processor_method

  def initialize(db_name:, processor_service:, processor_method: :process_document, **options)
    @db_name = db_name
    @processor_service = processor_service
    @processor_method = processor_method
    @config = DEFAULT_CONFIG.merge(options)

    validate_configuration!
  end

  # Build a listener for a registered database from its db_name alone, wiring the
  # correct processor service. Used by the worker job and the launcher rake.
  def self.build(db_name, **options)
    registration = PROCESSORS[db_name.to_s]
    raise ArgumentError, "No processor registered for CouchDB database '#{db_name}'" unless registration

    service_class, method_name = registration
    new(
      db_name: db_name,
      processor_service: service_class.constantize.new,
      processor_method: method_name,
      **options
    )
  end

  def start
    Rails.logger.info("[CouchDB Listener] Starting for #{db_name}...")
    Rails.logger.info("[CouchDB Listener] Process PID: #{Process.pid}")
    Rails.logger.info("[CouchDB Listener] Processor: #{processor_service}##{processor_method}")

    Rails.logger.info("[CouchDB Listener] process_all_unprocessed_documents on startup for #{db_name}")
    process_all_unprocessed_documents
    
    start_live_only
  end

  # Skips backfill and goes straight to the live changes feed.
  # Use this after process_all_unprocessed_documents has already been run sequentially.
  def start_live_only
    Rails.logger.info("[CouchDB Listener] Connecting to live changes feed for #{db_name}...")

    live_feed_started = false

    loop do
      begin
        if live_feed_started
          Rails.logger.info("[CouchDB Listener] Catching up unprocessed documents before reconnecting to #{db_name}")
          process_all_unprocessed_documents
        end

        live_feed_started = true
        listen_to_changes
      rescue Net::HTTPUnauthorized, Net::HTTPClientError => e
        Rails.logger.error("[CouchDB Listener] Authentication error for #{db_name}: #{e.message}. Reconnecting in #{config[:reconnect_delay]}s...")
        sleep(config[:reconnect_delay])
      rescue RestClient::Exception => e
        Rails.logger.error("[CouchDB Listener] RestClient error for #{db_name}: #{e.message}. Reconnecting in #{config[:reconnect_delay]}s...")
        sleep(config[:reconnect_delay])
      rescue StandardError => e
        Rails.logger.error("[CouchDB Listener] Unexpected error for #{db_name}: #{e.message}. Reconnecting in #{config[:reconnect_delay]}s...")
        Rails.logger.error("[CouchDB Listener] Error backtrace: #{e.backtrace.first(3).join(' -> ')}")
        sleep(config[:reconnect_delay])
      end
    end
  end

  # Starts all listeners concurrently, each running full backfill + live feed.
  def self.start_multiple(db_names, **options)
    threads = db_names.map do |db_name|
      Thread.new { build(db_name, **options).start }
    end

    threads.each(&:join)
  end

  # Starts all listeners concurrently on live feed only — backfill already done sequentially.
  def self.start_multiple_live_only(db_names, **options)
    threads = db_names.map do |db_name|
      Thread.new { build(db_name, **options).start_live_only }
    end

    threads.each(&:join)
  end

  def process_all_unprocessed_documents
    Rails.logger.info("[CouchDB Listener] Processing all unprocessed documents in #{db_name}...")
    ensure_unprocessed_index!

    return enqueue_all_unprocessed_documents if fan_out?

    begin
      total_processed = 0
      total_failed = 0

      loop do
        scan_result = process_unprocessed_document_scan

        if scan_result[:matched].zero?
          Rails.logger.info("[CouchDB Listener] No unprocessed documents found in #{db_name}")
          break
        end

        total_processed += scan_result[:processed]
        total_failed += scan_result[:failed]

        if scan_result[:processed].zero? && scan_result[:failed].positive? && scan_result[:failed_marked].zero?
          Rails.logger.error("[CouchDB Listener] No documents processed and no failures marked in latest pass for #{db_name}; stopping backfill to avoid a tight retry loop")
          break
        end
      end

      Rails.logger.info("[CouchDB Listener] Backfill pass finished for #{db_name}: processed=#{total_processed}, failed=#{total_failed}")

    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error processing unprocessed documents in #{db_name}: #{e.message}")
    end
  end

  # Fan-out entry point (Sync::CouchIngestJob): fetch the current doc by id and
  # process it inline, reusing the same path as the live listener. Idempotent —
  # skips docs already processed, missing, or dead-lettered — and on failure marks
  # the doc (retry/dead-letter) before re-raising so Sidekiq records the failure.
  def ingest_document(doc_id)
    doc = fetch_current_document(doc_id)
    unless doc
      Rails.logger.info("[CouchDB Listener] ingest: #{doc_id} not found in #{db_name}; skipping")
      return :missing
    end
    return :already_processed if doc['processed_by_listener'] == true
    return :dead_letter if listener_retry_exhausted?(doc)

    begin
      process_document(doc)
      :processed
    rescue StandardError => e
      mark_processing_failure(doc, e, source_rev: doc['_rev'])
      raise
    end
  end

  private

  def fan_out?
    config[:fan_out] == true
  end

  def enqueue_ingest(doc_id)
    return if doc_id.blank? || doc_id.to_s.start_with?('_design/')

    Sync::CouchIngestJob.perform_async(db_name, doc_id)
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Failed to enqueue ingest for #{doc_id} in #{db_name}: #{e.message}")
  end

  # Fan-out backfill: page through the unprocessed docs (via the Mango index) and
  # enqueue one job each, then return. Bookmark pagination is safe under the
  # workers concurrently marking docs processed — a doc removed before the scan
  # reaches it was already handled, and new writes are caught by the live feed.
  # Duplicate enqueues are deduped by the unique-jobs lock on (db_name, doc_id).
  def enqueue_all_unprocessed_documents
    total = 0
    bookmark = nil

    loop do
      page = find_unprocessed_page(backfill_scan_page_size, bookmark)
      docs = page['docs'] || []
      break if docs.empty?

      bookmark = page['bookmark']
      docs.each do |doc|
        next unless unprocessed_listener_document?(doc)

        enqueue_ingest(doc['_id'])
        total += 1
      end

      break if docs.size < backfill_scan_page_size
    end

    Rails.logger.info("[CouchDB Listener] Fan-out: enqueued #{total} unprocessed document(s) for #{db_name}")
    total
  end

  def validate_configuration!
    raise ArgumentError, "db_name is required" if db_name.blank?
    raise ArgumentError, "processor_service is required" if processor_service.blank?
    raise ArgumentError, "couchdb_url is required" if config[:couchdb_url].blank?
    
    unless processor_service.respond_to?(processor_method)
      raise ArgumentError, "#{processor_service} must respond to #{processor_method}"
    end
  end

  def listen_to_changes
    username, password = couchdb_credentials
    url = couchdb_url(db_name, '_changes')
    
    params = {
      feed: 'continuous',
      include_docs: true,
      timeout: config[:timeout],
      heartbeat: config[:heartbeat],
      since: 'now'
    }

    Rails.logger.info("[CouchDB Listener] Connecting to CouchDB changes feed for #{db_name}")

    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri)
      request.basic_auth(username, password) if username && password
      
      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise "HTTP #{response.code}: #{response.message}"
        end
        
        process_response_stream(response)
      end
    end
  end

  def process_response_stream(response)
    line_buffer = ""

    response.read_body do |chunk|
      line_buffer += chunk
      
      while (newline_pos = line_buffer.index("\n"))
        line = line_buffer[0...newline_pos].strip
        line_buffer = line_buffer[newline_pos + 1..-1]
        
        next if line.empty?
        
        begin
          change = JSON.parse(line)
          
          next unless change["doc"]
          
          doc = change["doc"]
          
          next if doc["processed_by_listener"] == true
          next if listener_retry_exhausted?(doc)
          
          if change["deleted"] == true
            Rails.logger.debug("[CouchDB Listener] Skipping deleted document: #{change['id']} in #{db_name}")
            next
          end
          
          Rails.logger.debug("[CouchDB Listener] Received change for unprocessed doc: #{change['id']} in #{db_name}")

          if fan_out?
            enqueue_ingest(doc['_id'])
          else
            process_changed_document(doc)
          end

        rescue JSON::ParserError => e
          Rails.logger.warn("[CouchDB Listener] Failed to parse JSON line in #{db_name}: #{line[0..100]}... Error: #{e.message}")
          next
        end
      end
    end
  end

  def process_unprocessed_document_scan
    result = { scanned: 0, matched: 0, processed: 0, failed: 0, failed_marked: 0 }

    # Re-query from the start each pass: processed docs flip to
    # processed_by_listener:true and dead-lettered docs are excluded by the
    # selector, so both drop out of the result set and the set drains to empty.
    loop do
      docs = fetch_unprocessed_documents(backfill_scan_page_size)
      break if docs.empty?

      result[:scanned] += docs.length

      unprocessed_docs = docs.select { |doc| unprocessed_listener_document?(doc) }
      break if unprocessed_docs.empty?

      result[:matched] += unprocessed_docs.length

      iter_processed = 0
      iter_failed = 0
      iter_failed_marked = 0
      unprocessed_docs.each_slice(config[:batch_size]) do |batch|
        batch_result = process_document_batch(batch)
        iter_processed += batch_result[:processed]
        iter_failed += batch_result[:failed]
        iter_failed_marked += batch_result[:failed_marked]
      end

      result[:processed] += iter_processed
      result[:failed] += iter_failed
      result[:failed_marked] += iter_failed_marked

      # No forward progress this pass (nothing processed AND no failure advanced
      # toward dead-letter) → the same docs would just be re-fetched, so stop.
      break if iter_processed.zero? && iter_failed_marked.zero?
    end

    Rails.logger.info(
      "[CouchDB Listener] Backfill (_find) for #{db_name}: scanned=#{result[:scanned]}, matched=#{result[:matched]}, processed=#{result[:processed]}, failed=#{result[:failed]}"
    )

    result
  end

  # Docs still awaiting processing (re-query from the start; for the inline drain
  # where processed docs flip to true and leave the result set).
  def fetch_unprocessed_documents(limit)
    find_unprocessed_page(limit)['docs'] || []
  end

  # One page of the Mango query for unprocessed, non-dead-lettered docs. Backed by
  # the processed_by_listener index (correct even without it — just slower).
  # Matches boolean false and the string "false" that some clients write, mirroring
  # unprocessed_listener_document?. Returns the raw response (docs + bookmark) so
  # the fan-out backfill can cursor through the whole set with the bookmark.
  def find_unprocessed_page(limit, bookmark = nil)
    username, password = couchdb_credentials
    resource_options = { headers: { content_type: :json, accept: :json } }
    resource_options[:user] = username if username
    resource_options[:password] = password if password

    body = {
      selector: {
        'processed_by_listener' => { '$in' => [false, 'false'] },
        'listener_dead_letter' => { '$exists' => false }
      },
      limit: limit
    }
    body[:bookmark] = bookmark if bookmark.present?

    response = RestClient::Resource.new(couchdb_url(db_name, '_find'), resource_options).post(body.to_json)
    return {} unless response.code == 200

    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] _find for unprocessed docs failed in #{db_name}: #{e.message}")
    {}
  end

  # Retry transient TiDB write failures (write conflicts, lock waits, deadlocks,
  # stale schema, region/TiKV blips). On single-node MySQL these are rare; on
  # distributed TiDB, concurrent writers hit them routinely, so the fan-out path
  # must retry rather than dead-letter a perfectly good document.
  TIDB_RETRYABLE = /try again later|write conflict|information schema is changed|tikv|region is unavailable|pd server timeout|lock|deadlock|\b(8002|8022|8027|9001|9005|9007)\b/i.freeze

  def with_tidb_retry(max_attempts: 5)
    attempt = 0
    begin
      yield
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
      attempt += 1
      raise if attempt >= max_attempts

      Rails.logger.warn("[CouchDB Listener] TiDB transient #{e.class} in #{db_name} (attempt #{attempt}/#{max_attempts}); retrying")
      sleep([0.05 * (2**(attempt - 1)), 2.0].min)
      retry
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.match?(TIDB_RETRYABLE)

      attempt += 1
      raise if attempt >= max_attempts

      Rails.logger.warn("[CouchDB Listener] TiDB transient write error in #{db_name} (attempt #{attempt}/#{max_attempts}): #{e.message.to_s[0, 120]}")
      sleep([0.05 * (2**(attempt - 1)), 2.0].min)
      retry
    end
  end

  # Create the Mango index that powers fetch_unprocessed_documents. Idempotent
  # (CouchDB returns "exists" for a duplicate) and non-fatal — without it _find
  # still returns correct results, just with a full scan.
  def ensure_unprocessed_index!
    return if @unprocessed_index_ensured

    username, password = couchdb_credentials
    resource_options = { headers: { content_type: :json, accept: :json } }
    resource_options[:user] = username if username
    resource_options[:password] = password if password

    body = {
      index: { fields: ['processed_by_listener'] },
      name: 'processed_by_listener_idx',
      ddoc: 'processed_by_listener_idx',
      type: 'json'
    }

    RestClient::Resource.new(couchdb_url(db_name, '_index'), resource_options).post(body.to_json)
    @unprocessed_index_ensured = true
    Rails.logger.info("[CouchDB Listener] Ensured processed_by_listener index for #{db_name}")
  rescue StandardError => e
    Rails.logger.warn("[CouchDB Listener] Could not ensure processed_by_listener index for #{db_name}: #{e.message}")
  end

  def unprocessed_listener_document?(doc)
    return false unless doc.is_a?(Hash)
    return false if doc['_id'].to_s.start_with?('_design/')
    return false unless doc['processed_by_listener'] == false || doc['processed_by_listener'].to_s.downcase == 'false'
    return false if listener_retry_exhausted?(doc)

    true
  end

  def backfill_scan_page_size
    configured_size = config[:backfill_scan_page_size].to_i
    configured_size.positive? ? configured_size : 1000
  end

  def listener_retry_exhausted?(doc)
    doc["listener_retry_count"].to_i >= config[:max_retry_attempts]
  end

  def process_document_batch(docs)
    Rails.logger.info("[CouchDB Listener] Processing batch of #{docs.length} documents in #{db_name}")

    processed = 0
    failed = 0
    failed_marked = 0

    docs.each do |doc|
      begin
        process_document(doc)
        processed += 1
      rescue StandardError => e
        failed += 1
        Rails.logger.error("[CouchDB Listener] Failed to process doc #{doc['_id']} in #{db_name}: #{e.message}")
        failed_marked += 1 if mark_processing_failure(doc, e, source_rev: doc['_rev'])
      end
    end

    { processed: processed, failed: failed, failed_marked: failed_marked }
  end

  def process_changed_document(doc)
    process_document(doc)
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Failed to process changed doc #{doc&.dig('_id')} in #{db_name}: #{e.message}")
    mark_processing_failure(doc, e, source_rev: doc&.dig('_rev'))
  end

  def process_document(doc)
    return unless doc
    
    doc_id = doc['_id']
    Rails.logger.info("[CouchDB Listener] Processing document: #{doc_id} in #{db_name}")
    
    begin
      Location.current = listener_location_for(doc)

      if doc["provider_id"].present?
        User.current = User.unscoped.find_by(user_id: doc["provider_id"])
        Rails.logger.warn("No user found for provider_id #{doc['provider_id']} in CouchDB doc #{doc_id}") unless User.current
      else
        Rails.logger.warn("No user_id found in CouchDB doc")
      end

      begin
        Thread.current['skip_couchdb_sync'] = true
        Thread.current[:skip_couchdb_sync] = true
        processed_data = with_tidb_retry do
          processor_service.send(processor_method, doc.with_indifferent_access)
        end
      ensure
        Thread.current['skip_couchdb_sync'] = false
        Thread.current[:skip_couchdb_sync] = false
      end

      if db_name == 'patients_records' && !processed_data.is_a?(Hash)
        raise "Patient record processing did not return a payload: #{processed_data.inspect}"
      end
      
      unless update_couchdb_with_retry(doc_id, processed_data, source_rev: doc['_rev'])
        raise "Failed to mark CouchDB document #{doc_id} as processed"
      end
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Failed to process document #{doc_id} in #{db_name}: #{e.message}")
      raise e
    end
  end

  def listener_location_for(doc)
    location_id = doc["location_id"].presence || doc[:location_id].presence
    Location.unscoped.find_by(location_id: location_id) || Location.current_health_center
  end

  def update_couchdb_with_retry(doc_id, processed_data, attempt = 1, source_rev: nil)
    return false if attempt > config[:max_retry_attempts]
    
    begin
      current_doc = fetch_current_document(doc_id)
      
      unless current_doc
        Rails.logger.error("[CouchDB Listener] Could not fetch current document for #{doc_id} in #{db_name}")
        return false
      end
      
      if current_doc["processed_by_listener"] == true
        Rails.logger.debug("[CouchDB Listener] Document #{doc_id} in #{db_name} already marked as processed, skipping update")
        return true
      end

      if source_rev.present? && current_doc["_rev"] != source_rev
        Rails.logger.warn("[CouchDB Listener] Document #{doc_id} in #{db_name} changed while processing; skipping stale listener update")
        return false
      end
      
      updated_doc = current_doc.dup
      updated_doc["processed_by_listener"] = true
      updated_doc["listener_processed_at"] = Time.current.iso8601
      updated_doc["processed_by_db"] = db_name
      
      if processed_data.present?
        cleaned_data = clean_for_json(processed_data)

        if cleaned_data.is_a?(Hash)
          cleaned_data.each do |key, value|
            next if key.to_s.start_with?('_') ||
                   key.to_s == 'processed_by_listener' ||
                   key.to_s == 'listener_processed_at' ||
                   key.to_s == 'processed_data' ||
                   key.to_s == 'processed_by_db'
            updated_doc[key.to_s] = value
          end
        end

        Rails.logger.info("[CouchDB Listener] Adding processed data to CouchDB document #{doc_id} in #{db_name}")
      end

      canonical_id = canonical_doc_id(updated_doc)

      if canonical_id.present? && canonical_id != doc_id
        rename_couchdb_document(doc_id, canonical_id, updated_doc)
      else
        update_couchdb_document_direct(doc_id, updated_doc)
      end
      
    rescue RestClient::Conflict, RestClient::PreconditionFailed => e
      Rails.logger.warn("[CouchDB Listener] Conflict on attempt #{attempt} for #{doc_id} in #{db_name}, retrying...")
      sleep(0.5 * (2 ** (attempt - 1)))
      update_couchdb_with_retry(doc_id, processed_data, attempt + 1, source_rev: source_rev)
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error updating document #{doc_id} in #{db_name} on attempt #{attempt}: #{e.message}")
      
      if attempt < config[:max_retry_attempts]
        sleep(1)
        update_couchdb_with_retry(doc_id, processed_data, attempt + 1, source_rev: source_rev)
      else
        false
      end
    end
  end

  def mark_processing_failure(doc, error, source_rev: nil)
    doc_id = doc['_id']
    current_doc = fetch_current_document(doc_id)
    return false unless current_doc
    return false if current_doc["processed_by_listener"] == true

    if source_rev.present? && current_doc["_rev"] != source_rev
      Rails.logger.warn("[CouchDB Listener] Document #{doc_id} in #{db_name} changed while failing; skipping stale failure marker")
      return false
    end

    current_doc["listener_retry_count"] = current_doc["listener_retry_count"].to_i + 1
    current_doc["listener_last_error"] = error.message
    current_doc["listener_failed_at"] = Time.current.iso8601
    current_doc["processed_by_db"] = db_name

    if current_doc["listener_retry_count"] >= config[:max_retry_attempts]
      current_doc["listener_dead_letter"] = true
      Rails.logger.error("[CouchDB Listener] Document #{doc_id} in #{db_name} reached max listener retries")
    end

    update_couchdb_document_direct(doc_id, current_doc)
  rescue RestClient::Conflict, RestClient::PreconditionFailed
    Rails.logger.warn("[CouchDB Listener] Conflict while marking processing failure for #{doc_id} in #{db_name}")
    false
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Failed to mark processing failure for #{doc_id} in #{db_name}: #{e.message}")
    false
  end

  def fetch_current_document(doc_id)
    begin
      username, password = couchdb_credentials
      encoded_doc_id = URI.encode_www_form_component(doc_id)
      fetch_url = couchdb_url(db_name, encoded_doc_id)
      
      resource_options = { headers: { accept: :json } }
      resource_options[:user] = username if username
      resource_options[:password] = password if password
      
      resource = RestClient::Resource.new(fetch_url, resource_options)
      response = resource.get
      
      response.code == 200 ? JSON.parse(response.body) : nil
      
    rescue RestClient::NotFound => e
      Rails.logger.error("[CouchDB Listener] Document not found when fetching #{doc_id} in #{db_name}: #{e.message}")
      nil
    rescue URI::InvalidURIError => e
      Rails.logger.error("[CouchDB Listener] Invalid URI when fetching document #{doc_id} in #{db_name}: #{e.message}")
      nil
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error fetching document #{doc_id} in #{db_name}: #{e.message}")
      nil
    end
  end

  def update_couchdb_document_direct(doc_id, document_data)
    username, password = couchdb_credentials
    encoded_doc_id = URI.encode_www_form_component(doc_id)
    update_url = couchdb_url(db_name, encoded_doc_id)

    resource_options = {
      headers: { content_type: :json, accept: :json }
    }
    resource_options[:user] = username if username
    resource_options[:password] = password if password

    resource = RestClient::Resource.new(update_url, resource_options)

    Rails.logger.debug("[CouchDB Listener] Updating document #{doc_id} in #{db_name} with revision #{document_data['_rev']}")

    response = resource.put(document_data.to_json)

    if response.code == 201 || response.code == 200
      response_data = JSON.parse(response.body)
      Rails.logger.info("[CouchDB Listener] Successfully updated CouchDB document: #{doc_id} in #{db_name}, new rev: #{response_data['rev']}")
      true
    else
      Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when updating document: #{doc_id} in #{db_name}")
      false
    end
  end

  # CouchDB doc ids are immutable, but the canonical identifier for patient
  # documents (the type-3 'National id') can change after the doc is first
  # written — for example when DDE re-links a patient or a merge runs. When
  # that happens we rewrite the document under the canonical id so `_id`
  # stays aligned with the `ID` field consumers read.
  def canonical_doc_id(updated_doc)
    return nil unless db_name == 'patients_records'

    identifier = updated_doc['ID'] || updated_doc[:ID]
    identifier.to_s.strip.presence
  end

  def rename_couchdb_document(old_id, new_id, document_data)
    Rails.logger.info("[CouchDB Listener] Renaming document #{old_id} -> #{new_id} in #{db_name}")

    if fetch_current_document(new_id)
      Rails.logger.error(
        "[CouchDB Listener] Cannot rename #{old_id} -> #{new_id} in #{db_name}: target id already exists. Updating old doc in place."
      )
      return update_couchdb_document_direct(old_id, document_data)
    end

    new_doc = document_data.reject { |key, _| key.to_s == '_id' || key.to_s == '_rev' }
    new_doc['_id'] = new_id

    create_couchdb_document_direct(new_id, new_doc)

    old_doc_rev = document_data['_rev']
    delete_couchdb_document_direct(old_id, old_doc_rev) if old_doc_rev.present?
    true
  rescue RestClient::Conflict => e
    Rails.logger.warn("[CouchDB Listener] Conflict renaming #{old_id} -> #{new_id} in #{db_name}: #{e.message}. Will retry via update_couchdb_with_retry.")
    raise
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Failed to rename #{old_id} -> #{new_id} in #{db_name}: #{e.message}. Falling back to in-place update.")
    update_couchdb_document_direct(old_id, document_data)
  end

  def create_couchdb_document_direct(doc_id, document_data)
    username, password = couchdb_credentials
    encoded_doc_id = URI.encode_www_form_component(doc_id)
    create_url = couchdb_url(db_name, encoded_doc_id)

    resource_options = { headers: { content_type: :json, accept: :json } }
    resource_options[:user] = username if username
    resource_options[:password] = password if password

    resource = RestClient::Resource.new(create_url, resource_options)
    response = resource.put(document_data.to_json)

    if response.code == 201 || response.code == 200
      response_data = JSON.parse(response.body)
      Rails.logger.info("[CouchDB Listener] Created CouchDB document: #{doc_id} in #{db_name}, rev: #{response_data['rev']}")
      true
    else
      raise "Unexpected response code #{response.code} when creating document: #{doc_id} in #{db_name}"
    end
  end

  def delete_couchdb_document_direct(doc_id, rev)
    username, password = couchdb_credentials
    encoded_doc_id = URI.encode_www_form_component(doc_id)
    delete_url = couchdb_url(db_name, "#{encoded_doc_id}?rev=#{rev}")

    resource_options = { headers: { accept: :json } }
    resource_options[:user] = username if username
    resource_options[:password] = password if password

    resource = RestClient::Resource.new(delete_url, resource_options)
    resource.delete

    Rails.logger.info("[CouchDB Listener] Deleted superseded CouchDB document: #{doc_id} in #{db_name}")
  rescue RestClient::NotFound
    Rails.logger.info("[CouchDB Listener] Old document #{doc_id} already gone in #{db_name}, nothing to delete")
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Failed to delete old document #{doc_id} in #{db_name}: #{e.message}")
  end

  def clean_for_json(data)
    case data
    when Hash
      data.each_with_object({}) do |(key, value), clean_hash|
        clean_hash[key.to_s] = clean_for_json(value)
      end
    when Array
      data.map { |item| clean_for_json(item) }
    when String, Numeric, TrueClass, FalseClass, NilClass
      data
    when Time, DateTime
      data.iso8601
    when Date
      data.to_s
    when ActiveRecord::Base
      begin
        clean_for_json(data.attributes)
      rescue
        data.to_s
      end
    when Symbol
      data.to_s
    else
      begin
        data.respond_to?(:attributes) ? clean_for_json(data.attributes) : data.to_s
      rescue
        nil
      end
    end
  end

  def couchdb_credentials
    CouchdbUrl.credentials(config[:couchdb_url], config[:username], config[:password])
  end

  def couchdb_url(*segments)
    CouchdbUrl.join(config[:couchdb_url], *segments, include_credentials: false)
  end
end
