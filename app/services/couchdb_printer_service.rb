require 'rest-client'
require 'json'
require 'yaml'

class CouchdbPrinterService
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  PRINTERS_DB = 'printer_configurations'

  class << self
    # Check if CouchDB is configured
    def couchdb_configured?
      COUCHDB_URL.present?
    end

    def ensure_db_exists(db_name = PRINTERS_DB)
      if couchdb_configured?
        RestClient.put("#{COUCHDB_URL}/#{db_name}", '')
      end
      true
    rescue RestClient::PreconditionFailed
      true # Database already exists
    rescue => e
      Rails.logger.error "CouchDB error: #{e.message}"
      false
    end

    # Get all printer configurations
    def get_all_printers
      ensure_db_exists
      
      response = RestClient.get(
        "#{COUCHDB_URL}/#{PRINTERS_DB}/_all_docs?include_docs=true"
      )
      
      result = JSON.parse(response.body)
      result['rows'].map { |row| row['doc'] }.reject { |doc| doc['_id'].start_with?('_design') }
    rescue => e
      Rails.logger.error "Error getting all printers: #{e.message}"
      []
    end

    # Get single printer configuration
    def get_printer(printer_id)
      ensure_db_exists
      
      response = RestClient.get("#{COUCHDB_URL}/#{PRINTERS_DB}/#{printer_id}")
      JSON.parse(response.body)
    rescue RestClient::NotFound
      nil
    rescue => e
      Rails.logger.error "Error getting printer #{printer_id}: #{e.message}"
      nil
    end

    # Create printer configuration
    def create_printer(printer_data)
      unless couchdb_configured?
        Rails.logger.warn "CouchDB not configured. Skipping create."
        return { success: false, error: 'CouchDB not configured' }
      end

      ensure_db_exists
      
      # Generate unique ID if not provided
      doc_id = printer_data[:id] || SecureRandom.uuid
      
      doc_data = {
        '_id' => doc_id,
        'ip_address' => printer_data[:ip_address],
        'port' => printer_data[:port],
        'location_id' => printer_data[:location_id],
        'printer_name' => printer_data[:printer_name],
        'created_at' => Time.current.iso8601,
        'updated_at' => Time.current.iso8601
      }

      response = RestClient.put(
        "#{COUCHDB_URL}/#{PRINTERS_DB}/#{doc_id}",
        doc_data.to_json,
        { content_type: :json, accept: :json }
      )
      
      result = JSON.parse(response.body)
      { success: true, id: result['id'], rev: result['rev'], data: doc_data }
    rescue => e
      Rails.logger.error "Error creating printer: #{e.message}"
      { success: false, error: e.message }
    end

    # Update printer configuration
    def update_printer(printer_id, printer_data)
      unless couchdb_configured?
        Rails.logger.warn "CouchDB not configured. Skipping update."
        return { success: false, error: 'CouchDB not configured' }
      end

      ensure_db_exists
      
      # Get existing document to retrieve _rev
      begin
        existing_doc = RestClient.get("#{COUCHDB_URL}/#{PRINTERS_DB}/#{printer_id}")
        existing_data = JSON.parse(existing_doc.body)
        
        # Merge updates with existing data
        doc_data = existing_data.merge({
          'ip_address' => printer_data[:ip_address] || existing_data['ip_address'],
          'port' => printer_data[:port] || existing_data['port'],
          'location_id' => printer_data[:location_id] || existing_data['location_id'],
          'printer_name' => printer_data[:printer_name] || existing_data['printer_name'],
          'updated_at' => Time.current.iso8601
        })

        response = RestClient.put(
          "#{COUCHDB_URL}/#{PRINTERS_DB}/#{printer_id}",
          doc_data.to_json,
          { content_type: :json, accept: :json }
        )
        
        result = JSON.parse(response.body)
        { success: true, id: result['id'], rev: result['rev'], data: doc_data }
      rescue RestClient::NotFound
        { success: false, error: 'Printer configuration not found' }
      end
    rescue => e
      Rails.logger.error "Error updating printer #{printer_id}: #{e.message}"
      { success: false, error: e.message }
    end

    # Delete printer configuration
    def delete_printer(printer_id)
      unless couchdb_configured?
        Rails.logger.warn "CouchDB not configured. Skipping delete."
        return { success: false, error: 'CouchDB not configured' }
      end

      ensure_db_exists
      
      # Get existing document to retrieve _rev
      begin
        existing_doc = RestClient.get("#{COUCHDB_URL}/#{PRINTERS_DB}/#{printer_id}")
        existing_data = JSON.parse(existing_doc.body)
        
        response = RestClient.delete(
          "#{COUCHDB_URL}/#{PRINTERS_DB}/#{printer_id}?rev=#{existing_data['_rev']}"
        )
        
        { success: true }
      rescue RestClient::NotFound
        { success: false, error: 'Printer configuration not found' }
      end
    rescue => e
      Rails.logger.error "Error deleting printer #{printer_id}: #{e.message}"
      { success: false, error: e.message }
    end

    # Find printers by location
    def find_by_location(location_id)
      ensure_db_exists
      create_location_index
      
      query = {
        selector: {
          location_id: location_id
        },
        use_index: "location_id_index"
      }
      
      response = RestClient.post(
        "#{COUCHDB_URL}/#{PRINTERS_DB}/_find",
        query.to_json,
        { content_type: :json, accept: :json }
      )
      
      result = JSON.parse(response.body)
      result['docs']
    rescue => e
      Rails.logger.error "Error finding printers by location: #{e.message}"
      []
    end

    private

    def create_location_index
      return unless couchdb_configured?

      index_doc = {
        index: {
          fields: ["location_id"]
        },
        name: "location_id_index",
        ddoc: "location_id_index",
        type: "json"
      }

      RestClient.post(
        "#{COUCHDB_URL}/#{PRINTERS_DB}/_index",
        index_doc.to_json,
        { content_type: :json, accept: :json }
      )
    rescue RestClient::ExceptionWithResponse => e
      if e.response.code == 409
        Rails.logger.info "Index already exists - continuing..."
      else
        Rails.logger.error "Error creating index: #{e.response&.body || e.message}"
      end
    end
  end
end