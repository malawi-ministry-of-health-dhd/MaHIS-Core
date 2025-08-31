require 'rest-client'
require 'json'
require 'yaml'

class CouchdbChangesListener
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  
  # Default configuration - can be overridden during initialization
  DEFAULT_CONFIG = {
    couchdb_url: CONFIG['COUCHDB_URL'],
    username: CONFIG['COUCHDB_USERNAME'],
    password: CONFIG['COUCHDB_PASSWORD'],
    reconnect_delay: 5,
    max_retry_attempts: 3,
    batch_size: 100,
    timeout: 60000,      # 60 second timeout
    heartbeat: 30000     # 30 second heartbeat
  }.freeze

  attr_reader :db_name, :config, :processor_service, :processor_method

  def initialize(db_name:, processor_service:, processor_method: :process_document, **options)
    @db_name = db_name
    @processor_service = processor_service
    @processor_method = processor_method
    @config = DEFAULT_CONFIG.merge(options)
    
    validate_configuration!
  end

  def start
    Rails.logger.info("[CouchDB Listener] Starting for #{db_name}...")
    Rails.logger.info("[CouchDB Listener] Process PID: #{Process.pid}")
    Rails.logger.info("[CouchDB Listener] Processor: #{processor_service}##{processor_method}")
    
    loop do
      begin
        listen_to_changes
      rescue Net::HTTPUnauthorized, Net::HTTPClientError => e
        Rails.logger.error("[CouchDB Listener] Authentication error for #{db_name}: #{e.message}. Check credentials. Reconnecting in #{config[:reconnect_delay]}s...")
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

  # Class method to create multiple listeners for different databases
  def self.start_multiple(database_configs)
    threads = []
    
    database_configs.each do |db_config|
      threads << Thread.new do
        listener = new(**db_config)
        listener.start
      end
    end
    
    # Wait for all threads to complete (they won't in normal operation)
    threads.each(&:join)
  end

  private

  def validate_configuration!
    raise ArgumentError, "db_name is required" if db_name.blank?
    raise ArgumentError, "processor_service is required" if processor_service.blank?
    raise ArgumentError, "couchdb_url is required" if config[:couchdb_url].blank?
    
    # Validate that the processor service exists and has the required method
    unless processor_service.respond_to?(processor_method)
      raise ArgumentError, "#{processor_service} must respond to #{processor_method}"
    end
  end

  def listen_to_changes
    # Parse the base COUCHDB_URL to extract credentials
    base_uri = URI(config[:couchdb_url])
    username = base_uri.user || config[:username]
    password = base_uri.password || config[:password]
    
    # Build clean URL without embedded credentials
    clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
    url = "#{clean_base_url}/#{db_name}/_changes"
    
    params = {
      feed: 'continuous',
      include_docs: true,
      timeout: config[:timeout],
      heartbeat: config[:heartbeat],
      since: 'now' # Start from current point, not from beginning
    }

    Rails.logger.info("[CouchDB Listener] Connecting to CouchDB changes feed for #{db_name}")

    # Use Net::HTTP for better streaming control
    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri)
      
      # Add authentication
      if username && password
        request.basic_auth(username, password)
      end
      
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
      
      # Process complete lines
      while (newline_pos = line_buffer.index("\n"))
        line = line_buffer[0...newline_pos].strip
        line_buffer = line_buffer[newline_pos + 1..-1]
        
        next if line.empty?
        
        begin
          change = JSON.parse(line)
          
          # Skip heartbeat messages
          next unless change["doc"]
          
          doc = change["doc"]
          
          # Skip if this document is already processed
          if doc["processed_by_listener"] == true
              next
          end
          
          # Skip deleted documents
          if change["deleted"] == true
            Rails.logger.debug("[CouchDB Listener] Skipping deleted document: #{change['id']} in #{db_name}")
            next
          end
          
          Rails.logger.debug("[CouchDB Listener] Received change for unprocessed doc: #{change['id']} in #{db_name}")
          
          # Process all unprocessed documents immediately
          process_all_unprocessed_documents
          
        rescue JSON::ParserError => e
          Rails.logger.warn("[CouchDB Listener] Failed to parse JSON line in #{db_name}: #{line[0..100]}... Error: #{e.message}")
          next
        end
      end
    end
  end

  def process_all_unprocessed_documents
    Rails.logger.info("[CouchDB Listener] Processing all unprocessed documents in #{db_name}...")
    
    begin
      unprocessed_docs = fetch_unprocessed_documents
      
      if unprocessed_docs.empty?
        Rails.logger.info("[CouchDB Listener] No unprocessed documents found in #{db_name}")
        return
      end
      
      Rails.logger.info("[CouchDB Listener] Found #{unprocessed_docs.length} unprocessed documents in #{db_name}")
      
      # Process documents in batches
      unprocessed_docs.each_slice(config[:batch_size]) do |batch|
        process_document_batch(batch)
      end
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error processing unprocessed documents in #{db_name}: #{e.message}")
    end
  end

  def fetch_unprocessed_documents
    base_uri = URI(config[:couchdb_url])
    username = base_uri.user || config[:username]
    password = base_uri.password || config[:password]
    
    clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
    
    # Use Mango query to filter documents server-side
    url = "#{clean_base_url}/#{db_name}/_find"
    
    # Mango query to find documents where processed_by_listener is not true
    query = {
      selector: {
        "$and" => [
          
          {
            "$or" => [
              { "processed_by_listener" => false },
            ]
          }
        ]
      },
      limit: 1000,
      execution_stats: false
    }
    
    resource_options = {
      headers: { 
        accept: :json,
        content_type: :json
      }
    }
    
    if username && password
      resource_options[:user] = username
      resource_options[:password] = password
    end
    
    resource = RestClient::Resource.new(url, resource_options)
    
    begin
      response = resource.post(query.to_json)
      
      if response.code == 200
        data = JSON.parse(response.body)
        Rails.logger.info("[CouchDB Listener] Found #{data['docs'].length} unprocessed documents using Mango query in #{db_name}")
        return data['docs']
      else
        Rails.logger.error("[CouchDB Listener] Failed to fetch documents with Mango query in #{db_name}: HTTP #{response.code}")
        return []
      end
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error with Mango query in #{db_name}: #{e.message}")
      return []
    end
  end

  def process_document_batch(docs)
    Rails.logger.info("[CouchDB Listener] Processing batch of #{docs.length} documents in #{db_name}")
    
    docs.each do |doc|
      begin
        process_document(doc)
      rescue StandardError => e
        Rails.logger.error("[CouchDB Listener] Failed to process doc #{doc['_id']} in #{db_name}: #{e.message}")
        # Continue processing other documents even if one fails
      end
    end
  end

  def process_document(doc)
    return unless doc
    
    doc_id = doc['_id']
    Rails.logger.info("[CouchDB Listener] Processing document: #{doc_id} in #{db_name}")
    
    begin
      if doc["provider_id"].present?
        User.current = User.find_by(user_id: doc["provider_id"])
      else
        Rails.logger.warn("No user_id found in CouchDB doc")
      end
      # Use the configurable processor service and method
      processed_data = processor_service.send(processor_method, doc.with_indifferent_access)
      
      # Mark as processed in CouchDB AND save the processed data back
      update_couchdb_with_retry(doc_id, processed_data)
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Failed to process document #{doc_id} in #{db_name}: #{e.message}")
      raise e
    end
  end

  def update_couchdb_with_retry(doc_id, processed_data, attempt = 1)
    return if attempt > config[:max_retry_attempts]
    
    begin
      # Fetch the latest document to get the current revision
      current_doc = fetch_current_document(doc_id)
      
      unless current_doc
        Rails.logger.error("[CouchDB Listener] Could not fetch current document for #{doc_id} in #{db_name}")
        return
      end
      
      # Check if already processed to avoid infinite loops
      if current_doc["processed_by_listener"] == true
        Rails.logger.debug("[CouchDB Listener] Document #{doc_id} in #{db_name} already marked as processed, skipping update")
        return
      end
      
      # Merge the processed data back into the CouchDB document
      updated_doc = current_doc.dup
      updated_doc["processed_by_listener"] = true
      updated_doc["listener_processed_at"] = Time.current.iso8601
      updated_doc["processed_by_db"] = db_name
      
      # Add the processed data
      if processed_data.present?
        # Clean the processed data for JSON serialization
        cleaned_data = clean_for_json(processed_data)
        updated_doc["processed_data"] = cleaned_data
        
        # Optionally merge specific fields directly into the root document
        if cleaned_data.is_a?(Hash)
          cleaned_data.each do |key, value|
            # Skip CouchDB reserved fields and existing metadata
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
      
      # Attempt to update
      update_couchdb_document_direct(doc_id, updated_doc)
      
    rescue RestClient::Conflict => e
      Rails.logger.warn("[CouchDB Listener] Conflict on attempt #{attempt} for #{doc_id} in #{db_name}, retrying...")
      
      # Exponential backoff
      sleep_time = 0.5 * (2 ** (attempt - 1))
      sleep(sleep_time)
      
      update_couchdb_with_retry(doc_id, processed_data, attempt + 1)
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error updating document #{doc_id} in #{db_name} on attempt #{attempt}: #{e.message}")
      
      if attempt < config[:max_retry_attempts]
        sleep(1)
        update_couchdb_with_retry(doc_id, processed_data, attempt + 1)
      end
    end
  end

  def fetch_current_document(doc_id)
    begin
      base_uri = URI(config[:couchdb_url])
      username = base_uri.user || config[:username]
      password = base_uri.password || config[:password]
      
      clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
      fetch_url = "#{clean_base_url}/#{db_name}/#{doc_id}"
      
      resource_options = {
        headers: { accept: :json }
      }
      
      if username && password
        resource_options[:user] = username
        resource_options[:password] = password
      end
      
      resource = RestClient::Resource.new(fetch_url, resource_options)
      response = resource.get
      
      if response.code == 200
        return JSON.parse(response.body)
      else
        Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when fetching document: #{doc_id} in #{db_name}")
        return nil
      end
      
    rescue RestClient::NotFound => e
      Rails.logger.error("[CouchDB Listener] Document not found when fetching #{doc_id} in #{db_name}: #{e.message}")
      return nil
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error fetching document #{doc_id} in #{db_name}: #{e.message}")
      return nil
    end
  end

  def update_couchdb_document_direct(doc_id, document_data)
    base_uri = URI(config[:couchdb_url])
    username = base_uri.user || config[:username]
    password = base_uri.password || config[:password]
    
    clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
    update_url = "#{clean_base_url}/#{db_name}/#{doc_id}"
    
    resource_options = {
      headers: {
        content_type: :json,
        accept: :json
      }
    }
    
    if username && password
      resource_options[:user] = username
      resource_options[:password] = password
    end
    
    resource = RestClient::Resource.new(update_url, resource_options)
    json_payload = document_data.to_json
    
    Rails.logger.debug("[CouchDB Listener] Updating document #{doc_id} in #{db_name} with revision #{document_data['_rev']}")
    
    response = resource.put(json_payload)
    
    if response.code == 201 || response.code == 200
      response_data = JSON.parse(response.body)
      Rails.logger.info("[CouchDB Listener] Successfully updated CouchDB document: #{doc_id} in #{db_name}, new rev: #{response_data['rev']}")
    else
      Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when updating document: #{doc_id} in #{db_name}")
    end
  end

  def clean_for_json(data)
    case data
    when Hash
      data.each_with_object({}) do |(key, value), clean_hash|
        clean_key = key.to_s
        clean_hash[clean_key] = clean_for_json(value)
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
      # Handle ActiveRecord objects by converting to hash
      begin
        clean_for_json(data.attributes)
      rescue
        data.to_s
      end
    when Symbol
      data.to_s
    else
      begin
        # Try to convert to hash if it responds to attributes
        if data.respond_to?(:attributes)
          clean_for_json(data.attributes)
        else
          data.to_s
        end
      rescue
        nil
      end
    end
  end
end