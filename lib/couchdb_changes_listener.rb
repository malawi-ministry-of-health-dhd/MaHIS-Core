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
    Rails.logger.info("[CouchDB Listener] Clean URL: #{url}")
    Rails.logger.info("[CouchDB Listener] Username: #{username ? username : 'NONE'}")
    Rails.logger.info("[CouchDB Listener] Password: #{password ? '[PRESENT]' : 'NONE'}")

    # Use Net::HTTP for better streaming control
    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri)
      
      # Add authentication
      if username && password
        request.basic_auth(username, password)
        Rails.logger.debug("[CouchDB Listener] Using basic authentication for user: #{username}")
      else
        Rails.logger.warn("[CouchDB Listener] No authentication credentials provided")
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
        
        # Handle heartbeat (empty lines)
        if line == ""
          next
        end
        
        begin
          change = JSON.parse(line)
          
          # Skip if no doc or if it's a heartbeat/last_seq update
          next unless change["doc"]
          
          save_seq(change["seq"]) if change["seq"]
          
          Rails.logger.debug("[CouchDB Listener] Received change for doc: #{change['id']}")
          
          # Check if document was already processed by us to prevent infinite loop
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

  # Check if we should process this change (prevent infinite loop)
  def should_process_change?(change)
    doc = change["doc"]
    return false unless doc
    
    # Skip if document was already processed by our listener
    # Note: Using field without underscore as CouchDB reserves underscore fields
    if doc["processed_by_listener"] == true
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
   
    # Save to MySQL and get the processed data back
    patient_data = SavePatientRecordService.new.create_patient_record(data.with_indifferent_access)
    
     Rails.logger.info("[CouchDB Listener] Processing patient: #{patient_data}")
    # Update CouchDB with the processed data and processing flag
    if patient_data
      update_couchdb_document(patient_id, doc["_rev"], patient_data)
    else
      Rails.logger.warn("[CouchDB Listener] No patient data returned from MySQL save operation for patient: #{patient_id}")
    end
  end

  def update_couchdb_document(doc_id, current_rev, updated_data)
    begin
      # Parse the base COUCHDB_URL to extract credentials
      base_uri = URI(COUCHDB_URL)
      username = base_uri.user || COUCHDB_USERNAME
      password = base_uri.password || COUCHDB_PASSWORD
      
      # Build clean URL without embedded credentials
      clean_base_url = "#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}"
      update_url = "#{clean_base_url}/#{DB_NAME}/#{doc_id}"
      
      # Validate inputs
      if doc_id.nil? || doc_id.empty?
        Rails.logger.error("[CouchDB Listener] Invalid doc_id: #{doc_id}")
        return
      end
      
      if current_rev.nil? || current_rev.empty?
        Rails.logger.error("[CouchDB Listener] Invalid current_rev: #{current_rev}")
        return
      end
      
      # Ensure updated_data is a hash and clean it
      unless updated_data.is_a?(Hash)
        Rails.logger.error("[CouchDB Listener] updated_data is not a hash: #{updated_data.class}")
        return
      end
      
      # Clean the updated_data to ensure it's JSON serializable
      clean_data = clean_for_json(updated_data)
      
      # Prepare the document for update with processing flag
      # Note: Using field without underscore as CouchDB reserves underscore fields
      updated_doc = clean_data.merge({
        "_id" => doc_id,
        "_rev" => current_rev,
        "processed_by_listener" => true,
        "listener_processed_at" => Time.current.iso8601
      })
      
      Rails.logger.info("[CouchDB Listener] Updating CouchDB document: #{doc_id}")
      Rails.logger.debug("[CouchDB Listener] Document ID: #{doc_id}")
      Rails.logger.debug("[CouchDB Listener] Current Rev: #{current_rev}")
      Rails.logger.debug("[CouchDB Listener] Update doc keys: #{updated_doc}")
      
      # Create RestClient resource with authentication
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
      
      # Convert to JSON and log the payload
      json_payload = updated_doc.to_json
      Rails.logger.debug("[CouchDB Listener] JSON payload size: #{json_payload.length} bytes")
      
      # Perform the update
      response = resource.put(json_payload)
      
      if response.code == 201 || response.code == 200
        response_data = JSON.parse(response.body)
        Rails.logger.info("[CouchDB Listener] Successfully updated CouchDB document: #{doc_id}, new rev: #{response_data['rev']} (marked as processed)")
      else
        Rails.logger.error("[CouchDB Listener] Unexpected response code #{response.code} when updating document: #{doc_id}")
      end
      
    rescue RestClient::BadRequest => e
      Rails.logger.error("[CouchDB Listener] Bad Request (400) when updating #{doc_id}: #{e.message}")
      if e.response
        Rails.logger.error("[CouchDB Listener] Response body: #{e.response.body}")
        begin
          error_data = JSON.parse(e.response.body)
          Rails.logger.error("[CouchDB Listener] CouchDB error details: #{error_data}")
        rescue JSON::ParserError
          Rails.logger.error("[CouchDB Listener] Could not parse error response as JSON")
        end
      end
    rescue RestClient::Conflict => e
      Rails.logger.error("[CouchDB Listener] Document conflict when updating #{doc_id}. Document may have been updated by another process: #{e.message}")
      # Optionally, you could implement retry logic here by fetching the latest revision
    rescue RestClient::NotFound => e
      Rails.logger.error("[CouchDB Listener] Document not found when trying to update #{doc_id}: #{e.message}")
    rescue RestClient::Exception => e
      Rails.logger.error("[CouchDB Listener] RestClient error when updating document #{doc_id}: #{e.message}")
    rescue JSON::ParserError => e
      Rails.logger.error("[CouchDB Listener] JSON parsing error when processing CouchDB response for #{doc_id}: #{e.message}")
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

  # Clean data to ensure it's JSON serializable
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
      # For any other object, try to convert to string
      begin
        data.to_s
      rescue
        nil
      end
    end
  end
end