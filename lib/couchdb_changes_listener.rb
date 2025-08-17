require 'rest-client'
require 'json'
require 'yaml'

class CouchdbChangesListener
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  COUCHDB_USERNAME = CONFIG['COUCHDB_USERNAME']
  COUCHDB_PASSWORD = CONFIG['COUCHDB_PASSWORD']
  DB_NAME = 'patients_records'
  SEQ_FILE = Rails.root.join('tmp', "couchdb_#{DB_NAME}_seq.txt")
  RECONNECT_DELAY = 5
  MAX_RETRY_ATTEMPTS = 3

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
    since = last_seq
    
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
      since: since,
      timeout: 60000, # 60 second timeout
      heartbeat: 30000 # 30 second heartbeat
    }

    Rails.logger.info("[CouchDB Listener] Connecting to CouchDB changes feed from seq: #{since}")

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
          
          # Skip if no doc or if it's a heartbeat/last_seq update
          next unless change["doc"]
          
          save_seq(change["seq"]) if change["seq"]
          
          Rails.logger.debug("[CouchDB Listener] Received change for doc: #{change['id']}")
          
          # Check if document should be processed
          if should_process_change?(change)
            process_change(change)
          else
            Rails.logger.debug("[CouchDB Listener] Skipping change - already processed by listener")
          end
          
        rescue JSON::ParserError => e
          Rails.logger.warn("[CouchDB Listener] Failed to parse JSON line: #{line[0..100]}... Error: #{e.message}")
          next
        end
      end
    end
  end

  def should_process_change?(change)
    doc = change["doc"]
    return false unless doc
    
    # Skip if document was already processed by our listener
    if doc["processed_by_listener"] == true
      return false
    end
    
    # Skip if this is a deletion
    if change["deleted"] == true
      Rails.logger.debug("[CouchDB Listener] Skipping deleted document: #{change['id']}")
      return false
    end
    
    true
  end

  def process_change(change)
    doc = change["doc"]
    return unless doc
    
    Rails.logger.info("[CouchDB Listener] Processing individual change for doc: #{change['id']}")
    
    begin
      save_to_mysql(doc)
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Failed to save doc #{doc['_id']}: #{e.message}")
    end
  end

  def save_to_mysql(doc)
    patient_id = doc["_id"]
    data = doc.except("_id", "_rev") # Remove CouchDB metadata
    
    Rails.logger.info("[CouchDB Listener] Processing patient: #{patient_id}")

    if doc["provider_id"].present?
      User.current = User.find_by(user_id: doc["provider_id"])
    else
      Rails.logger.warn("No user_id found in CouchDB doc")
    end
    
    # Save to MySQL and get the processed data back
    patient_data = SavePatientRecordService.new.create_patient_record(data.with_indifferent_access)
    
    Rails.logger.info("[CouchDB Listener] Processing patient data completed")
    
    # Update CouchDB with retry mechanism for conflicts
    if patient_data
      update_couchdb_with_retry(patient_id, patient_data)
    else
      Rails.logger.warn("[CouchDB Listener] No patient data returned from MySQL save operation for patient: #{patient_id}")
    end
  end

  # New method with retry mechanism for handling conflicts
  def update_couchdb_with_retry(doc_id, updated_data, attempt = 1)
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
      
      # Merge the updated data with current document, preserving CouchDB fields and any new fields
      merged_doc = merge_document_data(current_doc, updated_data)
      
      # Attempt to update
      update_couchdb_document_direct(doc_id, merged_doc)
      
    rescue RestClient::Conflict => e
      Rails.logger.warn("[CouchDB Listener] Conflict on attempt #{attempt} for #{doc_id}, retrying...")
      
      # Exponential backoff
      sleep_time = 0.5 * (2 ** (attempt - 1))
      sleep(sleep_time)
      
      update_couchdb_with_retry(doc_id, updated_data, attempt + 1)
      
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Error updating document #{doc_id} on attempt #{attempt}: #{e.message}")
      
      if attempt < MAX_RETRY_ATTEMPTS
        sleep(1)
        update_couchdb_with_retry(doc_id, updated_data, attempt + 1)
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

  # Merge document data intelligently
  def merge_document_data(current_doc, updated_data)
    # Start with the updated data (from MySQL processing)
    merged = clean_for_json(updated_data).dup
    
    # Preserve CouchDB metadata
    merged["_id"] = current_doc["_id"]
    merged["_rev"] = current_doc["_rev"]
    
    # Preserve any fields that might have been added by other processes
    # but prioritize our processed data
    current_doc.each do |key, value|
      # Skip CouchDB internal fields and our processing fields
      next if key.start_with?("_")
      next if ["processed_by_listener", "listener_processed_at"].include?(key)
      
      # If we don't have this field in our updated data, preserve it
      unless merged.key?(key)
        merged[key] = value
      end
    end
    
    # Mark as processed
    merged["processed_by_listener"] = true
    merged["listener_processed_at"] = Time.current.iso8601
    
    merged
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

  # Keep original method as fallback
  def update_couchdb_document(doc_id, current_rev, updated_data)
    begin
      base_uri = URI(COUCHDB_URL)
      username = base_uri.user || COUCHDB_USERNAME
      password = base_uri.password || COUCHDB_PASSWORD
      
      clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
      update_url = "#{clean_base_url}/#{DB_NAME}/#{doc_id}"
      
      if doc_id.nil? || doc_id.empty?
        Rails.logger.error("[CouchDB Listener] Invalid doc_id: #{doc_id}")
        return
      end
      
      if current_rev.nil? || current_rev.empty?
        Rails.logger.error("[CouchDB Listener] Invalid current_rev: #{current_rev}")
        return
      end
      
      unless updated_data.is_a?(Hash)
        Rails.logger.error("[CouchDB Listener] updated_data is not a hash: #{updated_data.class}")
        return
      end
      
      clean_data = clean_for_json(updated_data)
      
      updated_doc = clean_data.merge({
        "_id" => doc_id,
        "_rev" => current_rev,
        "processed_by_listener" => true,
        "listener_processed_at" => Time.current.iso8601
      })
      
      Rails.logger.info("[CouchDB Listener] Updating CouchDB document: #{doc_id}")
      
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
      json_payload = updated_doc.to_json
      
      response = resource.put(json_payload)
      
      if response.code == 201 || response.code == 200
        response_data = JSON.parse(response.body)
        Rails.logger.info("[CouchDB Listener] Successfully updated CouchDB document: #{doc_id}, new rev: #{response_data['rev']}")
      else
        Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when updating document: #{doc_id}")
      end
      
    rescue RestClient::Conflict => e
      Rails.logger.error("[CouchDB Listener] Document conflict when updating #{doc_id}. This should be handled by the retry mechanism.")
      raise e # Re-raise to trigger retry mechanism
    rescue RestClient::NotFound => e
      Rails.logger.error("[CouchDB Listener] Document not found when trying to update #{doc_id}: #{e.message}")
    rescue RestClient::Exception => e
      Rails.logger.error("[CouchDB Listener] RestClient error when updating document #{doc_id}: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[CouchDB Listener] Unexpected error when updating CouchDB document #{doc_id}: #{e.message}")
      Rails.logger.error("[CouchDB Listener] Error backtrace: #{e.backtrace.first(3).join(' -> ')}")
    end
  end

  def last_seq
    return "0" unless File.exist?(SEQ_FILE)
    seq = File.read(SEQ_FILE).strip
    seq.empty? ? "0" : seq
  end

  def save_seq(seq)
    return unless seq
    File.write(SEQ_FILE, seq)
  rescue StandardError => e
    Rails.logger.error("[CouchDB Listener] Failed to save sequence: #{e.message}")
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