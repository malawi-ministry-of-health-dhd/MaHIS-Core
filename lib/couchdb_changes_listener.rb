require 'rest-client'
require 'json'
require 'yaml'

class CouchdbChangesListener
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  COUCHDB_USERNAME = CONFIG['COUCHDB_USERNAME'] # Optional - can be nil if using URL-embedded credentials
  COUCHDB_PASSWORD = CONFIG['COUCHDB_PASSWORD'] # Optional - can be nil if using URL-embedded credentials
  DB_NAME = 'patients_records'
  SEQ_FILE = Rails.root.join('tmp', "couchdb_#{DB_NAME}_seq.txt")
  RECONNECT_DELAY = 5 # seconds

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
          
          # Process each change immediately
          process_change(change)
          
        rescue JSON::ParserError => e
          Rails.logger.warn("[CouchDB Listener] Failed to parse JSON line: #{line[0..100]}... Error: #{e.message}")
          next
        end
      end
    end
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
    Rails.logger.debug("[CouchDB Listener] Patient data: #{data}")
    
    # Uncomment and modify as needed:
    # patient = Patient.find_or_initialize_by(patient_id: patient_id)
    # patient.update!(data)
    
    # You might want to handle specific fields:
    # patient = Patient.find_or_initialize_by(patient_id: patient_id)
    # patient.assign_attributes(data.slice('name', 'age', 'diagnosis', ...))
    # patient.save!
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
end