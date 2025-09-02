# app/jobs/sync/dde_ids_sync_job.rb
module Sync
  class DdeIdsSyncJob < BaseSyncJob
    
    TARGET_ID_COUNT = 50 # Always maintain exactly 50 unassigned IDs
    
    # Sync DDE IDs to CouchDB to maintain exactly TARGET_ID_COUNT unassigned IDs
    def perform(location_id=700, batch_size = 100)
      db_name = 'dde'
      program_id = 14 # HIV Program - adjust as needed
      
      begin
        dde_service = DdeService.new(program: Program.find(program_id))
      rescue ActiveRecord::RecordNotFound
        Sidekiq.logger.error "Program with ID #{program_id} not found. Cannot initialize DDE service."
        raise "Program not found: #{program_id}"
      end
      
      # Check current count and calculate how many IDs we need to fetch
      ids_needed = calculate_ids_needed(db_name, location_id)
      
      if ids_needed <= 0
        Sidekiq.logger.info "Target count already met or exceeded. Current unassigned: #{TARGET_ID_COUNT - ids_needed}. No sync needed."
        return
      end
      
      Sidekiq.logger.info "Need to fetch #{ids_needed} DDE IDs to reach target of #{TARGET_ID_COUNT}"
      
      # Allocate only the exact number of IDs needed
      dde_ids = allocate_exact_dde_ids(dde_service, location_id, ids_needed, batch_size)
      
      if dde_ids.any?
        sync_array_to_couchdb(dde_ids, db_name, 'DDE IDs', batch_size, 
                             progress_interval: 50, rate_limit_interval: 10)
        
        # Verify final count
        final_count = get_couchdb_unassigned_dde_count(db_name, location_id)
        Sidekiq.logger.info "Sync completed. Final unassigned DDE IDs count: #{final_count}"
      else
        Sidekiq.logger.warn "No DDE IDs were allocated. Service may be unavailable."
      end
    end
    
    private
    
    def calculate_ids_needed(db_name, location_id)
      begin
        current_count = get_couchdb_unassigned_dde_count(db_name, location_id)
        ids_needed = TARGET_ID_COUNT - current_count
        
        Sidekiq.logger.info "Current unassigned DDE IDs in CouchDB: #{current_count}"
        Sidekiq.logger.info "Target count: #{TARGET_ID_COUNT}"
        Sidekiq.logger.info "IDs needed: #{ids_needed}"
        
        return ids_needed
        
      rescue => e
        Sidekiq.logger.error "Error calculating IDs needed: #{e.message}"
        # If we can't determine current count, assume we need all TARGET_ID_COUNT
        Sidekiq.logger.info "Assuming we need full target count due to error"
        return TARGET_ID_COUNT
      end
    end
    
    def allocate_exact_dde_ids(dde_service, location_id, ids_needed, batch_size)
      Sidekiq.logger.info "Starting allocation of exactly #{ids_needed} DDE IDs for location #{location_id}"
      
      all_dde_ids = []
      remaining_needed = ids_needed
      
      begin
        while remaining_needed > 0
          # Calculate batch size - don't request more than we need
          current_batch_size = [remaining_needed, batch_size].min
          
          begin
            Sidekiq.logger.info "Requesting #{current_batch_size} DDE IDs for location #{location_id} (#{remaining_needed} remaining)"
            response = dde_service.allocate_npids(current_batch_size, location_id)
            
            if response['npids'].nil? || response['npids'].empty?
              Sidekiq.logger.warn "No more DDE IDs available from service. Got #{all_dde_ids.length} out of #{ids_needed} requested."
              break
            end
            
            npids = response['npids']
            received_count = npids.length
            Sidekiq.logger.info "Received #{received_count} DDE IDs from DDE service"
            
            # Only take what we need (in case service returns more than requested)
            npids_to_add = npids.first([remaining_needed, received_count].min)
            all_dde_ids.concat(npids_to_add)
            remaining_needed -= npids_to_add.length
            
            # Log progress
            allocated_so_far = ids_needed - remaining_needed
            Sidekiq.logger.info "Progress: #{allocated_so_far}/#{ids_needed} DDE IDs allocated"
            
            # Pause between DDE service calls to avoid overwhelming the service
            sleep(0.5) if remaining_needed > 0
            
          rescue => e
            Sidekiq.logger.error "Error requesting DDE IDs: #{e.message}"
            break
          end
        end
        
      rescue => e
        Sidekiq.logger.error "Fatal error during DDE allocation: #{e.message}"
        raise e
      end
      
      final_count = all_dde_ids.length
      Sidekiq.logger.info "Completed DDE ID allocation: #{final_count}/#{ids_needed} IDs allocated"
      
      if final_count < ids_needed
        Sidekiq.logger.warn "Could not allocate full requested amount. Shortage: #{ids_needed - final_count} IDs"
      end
      
      all_dde_ids
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
        "_id" => generate_document_id(npid_data),
        "type" => "dde_id",
        "dde_id" => npid_data['npid'],
        "location_id" => npid_data['location_id'],
        "npid" => npid_data['npid'],
        "assigned" => npid_data.fetch('assigned', false),
        "allocated" => npid_data.fetch('allocated', true),
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(npid_data)
      "dde_id_#{npid_data['npid']}"
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
            "_id" => row['id'],
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
    
    # Method to manually adjust target count if needed
    def self.set_target_count(new_target)
      remove_const(:TARGET_ID_COUNT) if const_defined?(:TARGET_ID_COUNT)
      const_set(:TARGET_ID_COUNT, new_target)
      Sidekiq.logger.info "DDE IDs target count updated to #{new_target}"
    end
  end
end

# Usage examples:
# Sync::DdeIdsSyncJob.perform_async(700, 50)  # Sync for location 700 with batch size 50
# Sync::DdeIdsSyncJob.perform_async(700)      # Sync for location 700 with default batch size 100

# To clean assigned IDs and force resync:
# job = Sync::DdeIdsSyncJob.new
# job.send(:clean_assigned_dde_ids, 'dde', 700)

# To change the target count (if needed):
# Sync::DdeIdsSyncJob.set_target_count(100)  # Change target to 100 IDs