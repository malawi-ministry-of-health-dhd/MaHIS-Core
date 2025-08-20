require 'rest-client'
require 'json'
require 'yaml'

class CouchdbChangesListener
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  COUCHDB_USERNAME = CONFIG['COUCHDB_USERNAME']
  COUCHDB_PASSWORD = CONFIG['COUCHDB_PASSWORD']
  DB_NAME = 'patients_records'
  RECONNECT_DELAY = 5
  MAX_RETRY_ATTEMPTS = 3
  BATCH_SIZE = 100 # Process documents in batches

  def start
    Rails.logger.info("[CouchDB Listener] Starting for #{DB_NAME}...")
    Rails.logger.info("[CouchDB Listener] Process PID: #{Process.pid}")
    Rails.logger.info("[CouchDB Listener] Log level: #{Rails.logger.level}")
    loop do
      begin
        listen_to_changes
      rescue Net::HTTPUnauthorized, Net::HTTPClientError => e
        Rails.logger.error("[CouchDB Listener] Authentication error: #{e.message}. Check credentials. Reconnecting in #{RECONNECT_DELAY}s...")
        sleep(RECONNECT_DELAY)
      rescue RestClient::Exception => e
        Rails.logger.error("[CouchDB Listener] RestClient error: #{e.message}. Reconnecting in #{RECONNECT_DELAY}s...")
        sleep(RECONNECT_DELAY)
      rescue StandardError => e
        Rails.logger.error("[CouchDB Listener] Unexpected error: #{e.message}. Reconnecting in #{RECONNECT_DELAY}s...")
        Rails.logger.error("[CouchDB Listener] Error backtrace: #{e.backtrace.first(3).join(' -> ')}")
        sleep(RECONNECT_DELAY)
      end
    end
  end

  private

  def listen_to_changes
    # Parse the base COUCHDB_URL to extract credentials
    base_uri = URI(COUCHDB_URL)
    username = base_uri.user || COUCHDB_USERNAME
    password = base_uri.password || COUCHDB_PASSWORD
    
    # Build clean URL without embedded credentials
    clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
    url = "#{clean_base_url}/#{DB_NAME}/_changes"
    
    params = {
      feed: 'continuous',
      include_docs: true,
      timeout: 60000, # 60 second timeout
      heartbeat: 30000 # 30 second heartbeat
    }

    Rails.logger.info("[CouchDB Listener] Connecting to CouchDB changes feed")

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
          
          # Only process if there's an actual document change
          Rails.logger.debug("[CouchDB Listener] Received change for doc: #{change['id']}")
          
          # Process all unprocessed documents whenever any change occurs
          process_all_unprocessed_documents
          
        rescue JSON::ParserError => e
          Rails.logger.warn("[CouchDB Listener] Failed to parse JSON line: #{line[0..100]}... Error: #{e.message}")
          next
        end
      end
    end
  end

  def process_all_unprocessed_documents
    Rails.logger.info("[CouchDB Listener] Processing all unprocessed documents...")
    
    begin
      unprocessed_docs = fetch_unprocessed_documents
      
      if unprocessed_docs.empty?
        Rails.logger.info("[CouchDB Listener] No unprocessed documents found")
        return
      end
      
      Rails.logger.info("[CouchDB Listener] Found #{unprocessed_docs.length} unprocessed documents")
      
      # Process documents in batches
      unprocessed_docs.each_slice(BATCH_SIZE) do |batch|
        process_document_batch(batch)
      end
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error processing unprocessed documents: #{e.message}")
    end
  end

  def fetch_unprocessed_documents
    base_uri = URI(COUCHDB_URL)
    username = base_uri.user || COUCHDB_USERNAME
    password = base_uri.password || COUCHDB_PASSWORD
    
    clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
    
    # Use a view or _all_docs with a filter
    # First, let's try using _all_docs and filter on the client side
    url = "#{clean_base_url}/#{DB_NAME}/_all_docs"
    
    params = {
      include_docs: true,
      limit: 1000 # Adjust based on your needs
    }
    
    resource_options = {
      headers: { accept: :json }
    }
    
    if username && password
      resource_options[:user] = username
      resource_options[:password] = password
    end
    
    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    
    resource = RestClient::Resource.new(uri.to_s, resource_options)
    response = resource.get
    
    if response.code == 200
      data = JSON.parse(response.body)
      unprocessed_docs = []
      
      data['rows'].each do |row|
        doc = row['doc']
        next unless doc
        
        # Skip design documents
        next if doc['_id'].start_with?('_design/')
        
        # Skip deleted documents
        next if row['value']['deleted']
        
        # Only include documents that haven't been processed by listener
        if doc['processed_by_listener'] != true
          unprocessed_docs << doc
        end
      end
      
      return unprocessed_docs
    else
      Rails.logger.error("[CouchDB Listener] Failed to fetch documents: HTTP #{response.code}")
      return []
    end
    
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Error fetching unprocessed documents: #{e.message}")
    return []
  end

  def process_document_batch(docs)
    Rails.logger.info("[CouchDB Listener] Processing batch of #{docs.length} documents")
    
    docs.each do |doc|
      begin
        process_document(doc)
      rescue StandardError => e
        Rails.logger.error("[CouchDB Listener] Failed to process doc #{doc['_id']}: #{e.message}")
        # Continue processing other documents even if one fails
      end
    end
  end

  def process_document(doc)
    return unless doc
    
    doc_id = doc['_id']
    Rails.logger.info("[CouchDB Listener] Processing document: #{doc_id}")
    
    begin
      # Save to MySQL
      save_to_mysql(doc)
      
      # Mark as processed in CouchDB
      update_couchdb_with_retry(doc_id, doc)
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Failed to process document #{doc_id}: #{e.message}")
      raise e
    end
  end

  def save_to_mysql(doc)
    patient_id = doc["_id"]
    data = doc.except("_id", "_rev", "processed_by_listener", "listener_processed_at") # Remove CouchDB metadata
    
    Rails.logger.info("[CouchDB Listener] Processing patient: #{patient_id}")

    if doc["provider_id"].present?
      User.current = User.find_by(user_id: doc["provider_id"])
    else
      Rails.logger.warn("No user_id found in CouchDB doc")
    end
    
    # Save to MySQL and get the processed data back
    patient_data = SavePatientRecordService.new.create_patient_record(data.with_indifferent_access)
    
    Rails.logger.info("[CouchDB Listener] Processing patient data completed for #{patient_id}")
    
    return patient_data
  end

  # Updated retry mechanism - now just marks document as processed
  def update_couchdb_with_retry(doc_id, original_doc, attempt = 1)
    return if attempt > MAX_RETRY_ATTEMPTS
    
    begin
      # Fetch the latest document to get the current revision
      current_doc = fetch_current_document(doc_id)
      
      unless current_doc
        Rails.logger.error("[CouchDB Listener] Could not fetch current document for #{doc_id}")
        return
      end
      
      # Check if already processed to avoid infinite loops
      if current_doc["processed_by_listener"] == true
        Rails.logger.debug("[CouchDB Listener] Document #{doc_id} already marked as processed, skipping update")
        return
      end
      
      # Just mark as processed (don't merge MySQL data back)
      updated_doc = current_doc.dup
      updated_doc["processed_by_listener"] = true
      updated_doc["listener_processed_at"] = Time.current.iso8601
      
      # Attempt to update
      update_couchdb_document_direct(doc_id, updated_doc)
      
    rescue RestClient::Conflict => e
      Rails.logger.warn("[CouchDB Listener] Conflict on attempt #{attempt} for #{doc_id}, retrying...")
      
      # Exponential backoff
      sleep_time = 0.5 * (2 ** (attempt - 1))
      sleep(sleep_time)
      
      update_couchdb_with_retry(doc_id, original_doc, attempt + 1)
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error updating document #{doc_id} on attempt #{attempt}: #{e.message}")
      
      if attempt < MAX_RETRY_ATTEMPTS
        sleep(1)
        update_couchdb_with_retry(doc_id, original_doc, attempt + 1)
      end
    end
  end

  # Fetch the current document from CouchDB to get latest revision
  def fetch_current_document(doc_id)
    begin
      base_uri = URI(COUCHDB_URL)
      username = base_uri.user || COUCHDB_USERNAME
      password = base_uri.password || COUCHDB_PASSWORD
      
      clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
      fetch_url = "#{clean_base_url}/#{DB_NAME}/#{doc_id}"
      
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
        Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when fetching document: #{doc_id}")
        return nil
      end
      
    rescue RestClient::NotFound => e
      Rails.logger.error("[CouchDB Listener] Document not found when fetching #{doc_id}: #{e.message}")
      return nil
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error fetching document #{doc_id}: #{e.message}")
      return nil
    end
  end

  # Direct document update method
  def update_couchdb_document_direct(doc_id, document_data)
    base_uri = URI(COUCHDB_URL)
    username = base_uri.user || COUCHDB_USERNAME
    password = base_uri.password || COUCHDB_PASSWORD
    
    clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
    update_url = "#{clean_base_url}/#{DB_NAME}/#{doc_id}"
    
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
    
    Rails.logger.debug("[CouchDB Listener] Updating document #{doc_id} with revision #{document_data['_rev']}")
    
    response = resource.put(json_payload)
    
    if response.code == 201 || response.code == 200
      response_data = JSON.parse(response.body)
      Rails.logger.info("[CouchDB Listener] Successfully updated CouchDB document: #{doc_id}, new rev: #{response_data['rev']}")
    else
      Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when updating document: #{doc_id}")
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
    else
      begin
        data.to_s
      rescue
        nil
      end
    end
  end
end