# app/jobs/sync/dde_ids_sync_job.rb
module Sync
  class DdeIdsSyncJob < BaseSyncJob
    
    # Sync all available DDE IDs to CouchDB for offline access
    def perform(location_id, batch_size = 100)
      db_name = 'dde'
      program_id = 14 # HIV Program - adjust as needed
      
      begin
        dde_service = DdeService.new(program: Program.find(program_id))
      rescue ActiveRecord::RecordNotFound
        Sidekiq.logger.error "Program with ID #{program_id} not found. Cannot initialize DDE service."
        raise "Program not found: #{program_id}"
      end
      
      # Check if we need to sync by comparing available vs stored IDs
      return if check_and_manage_dde_ids_if_needed(db_name, dde_service, location_id) == :skip_sync
      
      # Allocate IDs and sync them using the base class array sync method
      dde_ids = allocate_dde_ids_in_batches(dde_service, location_id, batch_size)
      sync_array_to_couchdb(dde_ids, db_name, 'DDE IDs', batch_size, 
                           progress_interval: 50, rate_limit_interval: 10)
    end
    
    private
    
    def allocate_dde_ids_in_batches(dde_service, location_id, batch_size)
      Sidekiq.logger.info "Starting allocation of DDE IDs for location #{location_id}"
      
      all_dde_ids = []
      total_allocated = 0
      
      begin
        loop do
          begin
            # Request batch of IDs from DDE service
            Sidekiq.logger.info "Requesting #{batch_size} DDE IDs for location #{location_id}"
            response = dde_service.allocate_npids(batch_size, location_id)
            
            if response['npids'].nil? || response['npids'].empty?
              Sidekiq.logger.info "No more DDE IDs available for allocation. Allocation completed."
              break
            end
            
            npids = response['npids']
            Sidekiq.logger.info "Received #{npids.length} DDE IDs from DDE service"
            
            all_dde_ids.concat(npids)
            total_allocated += npids.length
            
            # Pause between DDE service calls to avoid overwhelming the service
            sleep(0.5)
            Sidekiq.logger.info "Allocated #{total_allocated} DDE IDs so far."
            
          rescue => e
            Sidekiq.logger.error "Error requesting DDE IDs: #{e.message}"
            break
          end
          
          # Safety check to prevent infinite loops
          if total_allocated >= 10000 # Adjust limit as needed
            Sidekiq.logger.warn "Reached allocation limit (#{total_allocated}). Stopping allocation."
            break
          end
        end
        
      rescue => e
        Sidekiq.logger.error "Fatal error during DDE allocation: #{e.message}"
        raise e
      end
      
      Sidekiq.logger.info "Completed DDE ID allocation: #{all_dde_ids.length} IDs ready for sync"
      all_dde_ids
    end
    
    def check_and_manage_dde_ids_if_needed(db_name, dde_service, location_id)
      begin
        # Get count of unassigned DDE IDs in CouchDB for this location
        couchdb_unassigned_count = get_couchdb_unassigned_dde_count(db_name, location_id)
        
        Sidekiq.logger.info "CouchDB unassigned DDE IDs for location #{location_id}: #{couchdb_unassigned_count}"
        
        # Define minimum threshold of unassigned IDs to maintain
        min_threshold = 50 # Adjust as needed
        
        if couchdb_unassigned_count >= min_threshold
          Sidekiq.logger.info "Sufficient unassigned DDE IDs available (#{couchdb_unassigned_count} >= #{min_threshold}). Skipping sync."
          return :skip_sync
        else
          Sidekiq.logger.info "Low unassigned DDE IDs count (#{couchdb_unassigned_count} < #{min_threshold}). Proceeding with sync."
          return :continue_sync
        end
        
      rescue => e
        Sidekiq.logger.error "Error checking CouchDB DDE IDs count: #{e.message}"
        Sidekiq.logger.info "Proceeding with sync despite count check failure..."
        return :continue_sync
      end
    end
    
    def get_couchdb_unassigned_dde_count(db_name, location_id)
      begin
        db_url = "#{COUCHDB_URL}/#{db_name}"
        
        # Try to get the database info first
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
          return 0
        end
        
        # Get count of unassigned DDE ID documents for this location using URL encoding
        require 'uri'
        start_key = URI.encode_www_form_component('"dde_id_"')
        end_key = URI.encode_www_form_component('"dde_id_\ufff0"')
        
        view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        # Count unassigned IDs for this location
        unassigned_count = result['rows'].count do |row|
          doc = row['doc']
          doc['location_id'] == location_id && doc['assigned'] == false
        end
        
        return unassigned_count
        
      rescue => e
        Sidekiq.logger.error "Error getting CouchDB DDE IDs count: #{e.message}"
        raise e
      end
    end
    
    def prepare_document(npid_data)
      {
        "type" => "dde_id",
        "dde_id" => npid_data['npid'],
        "location_id" => npid_data['location_id'],
        "npid" => npid_data['npid'],
        "assigned" => npid_data['assigned'],
        "allocated" => npid_data['allocated'],
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(npid_data)
      npid_data['npid']
    end
    
    def clean_assigned_dde_ids(db_name, location_id)
      begin
        db_url = "#{COUCHDB_URL}/#{db_name}"
        
        # First, check if database exists
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
          return
        end
        
        # Get all assigned DDE ID documents for this location
        require 'uri'
        start_key = URI.encode_www_form_component('"dde_id_"')
        end_key = URI.encode_www_form_component('"dde_id_\ufff0"')
        
        view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        # Filter for assigned IDs at this location
        assigned_docs = result['rows'].select do |row|
          doc = row['doc']
          doc['location_id'] == location_id && doc['assigned'] == true
        end
        
        if assigned_docs.empty?
          Sidekiq.logger.info "No assigned DDE ID documents found for location #{location_id}. Nothing to clean."
          return
        end
        
        Sidekiq.logger.info "Found #{assigned_docs.length} assigned DDE ID documents to delete for location #{location_id}"
        
        # Use the base class bulk delete functionality
        docs_to_delete = assigned_docs.map do |row|
          {
            "_id" => row['npid'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        perform_bulk_delete("#{COUCHDB_URL}/#{db_name}", docs_to_delete, "assigned DDE IDs")
        
      rescue => e
        Sidekiq.logger.error "Error cleaning assigned DDE IDs from CouchDB: #{e.message}"
        raise e
      end
    end
  end
end

# Usage examples:
# Sync::DdeIdsSyncJob.perform_async(700, 50)  # Sync for location 700 with batch size 50
# Sync::DdeIdsSyncJob.perform_async(700)      # Sync for location 700 with default batch size 100

# To clean assigned IDs and force resync:
# job = Sync::DdeIdsSyncJob.new
# job.send(:clean_assigned_dde_ids, 'dde', 700)