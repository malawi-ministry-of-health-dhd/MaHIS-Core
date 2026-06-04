# app/jobs/sync/dde_ids_sync_job.rb
module Sync
  class DdeIdsSyncJob < BaseSyncJob
    
    TARGET_ID_COUNT = 50 # Always maintain exactly 50 unassigned IDs per facility
    FACILITIES_DB_NAME = 'facilities' # Name of the facilities database
    CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
    DDE_LOCATION_ID = CONFIG['DDE_LOCATION_ID']
    
    # Sync DDE IDs to CouchDB for all DDE-activated facilities
    def perform(batch_size = 100)
      db_name = 'dde'
      program_id = 14 # OPD Program - adjust as needed
      
      begin
        dde_service = DdeService.new(program: Program.find(program_id))
      rescue ActiveRecord::RecordNotFound
        Sidekiq.logger.error "Program with ID #{program_id} not found. Cannot initialize DDE service."
        raise "Program not found: #{program_id}"
      end
      
      # Get all DDE-activated facilities
      dde_facilities = get_dde_activated_facilities
      
      if dde_facilities.empty?
        Sidekiq.logger.info "No DDE-activated facilities found. No sync needed."
        return
      end
      
      Sidekiq.logger.info "Processing #{dde_facilities.length} DDE-activated facilities for location #{DDE_LOCATION_ID}"
      
      # Process each facility
      dde_facilities.each_with_index do |facility, index|
        location_id = facility['location_id']
        
        Sidekiq.logger.info "Processing facility #{index + 1}/#{dde_facilities.length}: #{location_id}"
        
        begin
          process_facility_dde_sync(dde_service, location_id, db_name, batch_size)
        rescue => e
          Sidekiq.logger.error "Error processing facility #{location_id}: #{e.message}"
          # Continue with other facilities
        end
        
        # Small delay between facilities to avoid overwhelming the DDE service
        sleep(1) if index < dde_facilities.length - 1
      end
      
      Sidekiq.logger.info "Completed DDE sync for all facilities at location #{DDE_LOCATION_ID}"
    end
    
    private
    
    def get_dde_activated_facilities
      begin
        facilities_db_url = couchdb_url(FACILITIES_DB_NAME)
        
        # Check if facilities database exists
        begin
          RestClient.get(facilities_db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.error "Facilities database '#{FACILITIES_DB_NAME}' not found."
          return []
        end
        
        # Get all documents from facilities database
        view_url = "#{facilities_db_url}/_all_docs?include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        # Filter facilities with dde_activated = true
        dde_facilities = result['rows'].filter_map do |row|
          doc = row['doc']
          next if doc['_id'].start_with?('_design') # Skip design documents
          
          if doc['dde_activated'] == true
            {
              'location_id' => doc['location_id'],
              'name' => doc['name'],
              'facility_id' => doc['_id']
            }
          end
        end.compact
        
        Sidekiq.logger.info "Found #{dde_facilities.length} DDE-activated facilities"
        dde_facilities
        
      rescue => e
        Sidekiq.logger.error "Error fetching DDE-activated facilities: #{e.message}"
        []
      end
    end
    
    def process_facility_dde_sync(dde_service, location_id, db_name, batch_size)
      # Check current count and calculate how many IDs we need to fetch for this facility
      ids_needed = calculate_facility_ids_needed(db_name, location_id)
      
      if ids_needed <= 0
        current_count = TARGET_ID_COUNT - ids_needed
        Sidekiq.logger.info "Facility #{location_id}: Target count already met. Current unassigned: #{current_count}"
        return
      end
      
      Sidekiq.logger.info "Facility #{location_id}: Need to fetch #{ids_needed} DDE IDs to reach target of #{TARGET_ID_COUNT}"
      
      # Allocate only the exact number of IDs needed for this facility
      dde_ids = allocate_exact_dde_ids_for_facility(dde_service, location_id, ids_needed, batch_size)
      
      if dde_ids.any?
        # Convert raw DDE IDs to properly formatted CouchDB documents
        formatted_documents = dde_ids.map { |dde_id| prepare_document(dde_id) }
        
        sync_array_to_couchdb(formatted_documents, db_name, "dde_id", batch_size, 
                             progress_interval: 25, rate_limit_interval: 5)
        
        # Verify final count for this facility
        final_count = get_facility_unassigned_dde_count(db_name, location_id)
        Sidekiq.logger.info "Facility #{location_id}: Sync completed. Final unassigned DDE IDs count: #{final_count}"
      else
        Sidekiq.logger.warn "Facility #{location_id}: No DDE IDs were allocated. Service may be unavailable."
      end
    end
    
    def calculate_facility_ids_needed(db_name, location_id)
      begin
        current_count = get_facility_unassigned_dde_count(db_name, location_id)
        ids_needed = TARGET_ID_COUNT - current_count
        
        Sidekiq.logger.info "Facility #{location_id}: Current unassigned DDE IDs: #{current_count}, Target: #{TARGET_ID_COUNT}, Needed: #{ids_needed}"
        
        return ids_needed
        
      rescue => e
        Sidekiq.logger.error "Error calculating IDs needed for facility #{location_id}: #{e.message}"
        # If we can't determine current count, assume we need all TARGET_ID_COUNT
        return TARGET_ID_COUNT
      end
    end
    
    def allocate_exact_dde_ids_for_facility(dde_service, location_id, ids_needed, batch_size)
      Sidekiq.logger.info "Starting allocation of exactly #{ids_needed} DDE IDs for facility #{location_id} at location #{DDE_LOCATION_ID}"
      
      all_dde_ids = []
      remaining_needed = ids_needed
      
      begin
        while remaining_needed > 0
          # Calculate batch size - don't request more than we need
          current_batch_size = [remaining_needed, batch_size].min
          
          begin
            Sidekiq.logger.info "Facility #{location_id}: Requesting #{current_batch_size} DDE IDs for location #{location_id} (#{remaining_needed} remaining)"
            response = dde_service.allocate_npids(current_batch_size, DDE_LOCATION_ID)
            
            if response['npids'].nil? || response['npids'].empty?
              Sidekiq.logger.warn "Facility #{location_id}: No more DDE IDs available from service. Got #{all_dde_ids.length} out of #{ids_needed} requested."
              break
            end
            
            npids = response['npids']
            received_count = npids.length
            Sidekiq.logger.info "Facility #{location_id}: Received #{received_count} DDE IDs from DDE service"
            
            # Only take what we need and add facility information
            npids_to_add = npids.first([remaining_needed, received_count].min).map do |npid_data|
              # Handle both string NPIDs and hash NPIDs from DDE service
              if npid_data.is_a?(Hash)
                # Extract the actual NPID string from the hash
                actual_npid = npid_data['npid'] || npid_data[:npid]
                {
                  'npid' => actual_npid,
                  'dde_location_id' => DDE_LOCATION_ID,
                  'location_id' => location_id,
                  'assigned' => npid_data['assigned'] || npid_data[:assigned] || false,
                  'allocated' => npid_data['allocated'] || npid_data[:allocated] || true,
                  'dde_id' => npid_data['id'] || npid_data[:id] # Store original DDE ID if available
                }
              else
                # Handle simple string NPIDs
                {
                  'npid' => npid_data,
                  'dde_location_id' => DDE_LOCATION_ID,
                  'location_id' => location_id,
                  'assigned' => false,
                  'allocated' => true
                }
              end
            end
            
            all_dde_ids.concat(npids_to_add)
            remaining_needed -= npids_to_add.length
            
            # Log progress
            allocated_so_far = ids_needed - remaining_needed
            Sidekiq.logger.info "Facility #{location_id}: Progress: #{allocated_so_far}/#{ids_needed} DDE IDs allocated"
            
            # Pause between DDE service calls to avoid overwhelming the service
            sleep(0.5) if remaining_needed > 0
            
          rescue => e
            Sidekiq.logger.error "Facility #{location_id}: Error requesting DDE IDs: #{e.message}"
            break
          end
        end
        
      rescue => e
        Sidekiq.logger.error "Facility #{location_id}: Fatal error during DDE allocation: #{e.message}"
        raise e
      end
      
      final_count = all_dde_ids.length
      Sidekiq.logger.info "Facility #{location_id}: Completed DDE ID allocation: #{final_count}/#{ids_needed} IDs allocated"
      
      if final_count < ids_needed
        Sidekiq.logger.warn "Facility #{location_id}: Could not allocate full requested amount. Shortage: #{ids_needed - final_count} IDs"
      end
      
      all_dde_ids
    end
    
    def get_facility_unassigned_dde_count(db_name, location_id)
      begin
        db_url = couchdb_url(db_name)
        
        # Try to get the database info first
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
          return 0
        end
        
        # Get count of unassigned DDE ID documents for this facility and location using URL encoding
        require 'uri'
        start_key = URI.encode_www_form_component('"dde_id_"')
        end_key = URI.encode_www_form_component('"dde_id_\ufff0"')
        
        view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        # Count unassigned IDs for this facility and location
        # Note: location_id might not exist in older documents, so we check both conditions
        # Compare as strings because prepare_document stores location_id via .to_s
        unassigned_count = result['rows'].count do |row|
          doc = row['doc']
          doc['dde_location_id'].to_s == DDE_LOCATION_ID.to_s &&
          (doc['status'].nil? || doc['status'].empty? || doc['status'] != 'used') &&
          (doc['location_id'].to_s == location_id.to_s || doc['location_id'].nil?)
        end
        
        return unassigned_count
        
      rescue => e
        Sidekiq.logger.error "Error getting CouchDB DDE IDs count for facility #{location_id}: #{e.message}"
        raise e
      end
    end
    
    def prepare_document(npid_data)
      # Extract the actual NPID string - handle both hash and string formats
      actual_npid = if npid_data['npid'].is_a?(Hash)
                      npid_data['npid']['npid'] || npid_data['npid'][:npid]
                    else
                      npid_data['npid']
                    end
                    
      {
        "_id" => generate_document_id(npid_data, actual_npid),
        "dde_id" => actual_npid,
        "dde_location_id" => npid_data['dde_location_id'],
        "location_id" => npid_data['location_id'].to_s,
        "npid" => actual_npid,
        "assigned" => npid_data.fetch('assigned', false),
        "allocated" => npid_data.fetch('allocated', true),
        "original_dde_data" => npid_data['dde_id'], # Store original DDE data if available
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(npid_data, actual_npid = nil)
      # Use the actual NPID string for document ID
      npid_string = actual_npid || npid_data['npid']
      
      # Include facility code in document ID to ensure uniqueness across facilities
      "dde_id_#{npid_data['location_id']}_#{npid_string}"
    end
    
    def clean_assigned_dde_ids(db_name, location_id= nil)
      begin
        db_url = couchdb_url(db_name)
        
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
        
        # Filter for assigned IDs at this location (and optionally specific facility)
        assigned_docs = result['rows'].select do |row|
          doc = row['doc']
          matches_location = doc['dde_location_id'] == DDE_LOCATION_ID && doc['assigned'] == true
          
          # If location_id is specified, also filter by location
          # Note: Handle older documents that might not have location_id
          if location_id
            matches_location && (doc['location_id'] == location_id || doc['location_id'].nil?)
          else
            matches_location
          end
        end
        
        if assigned_docs.empty?
          filter_msg = location_id ? "location #{location_id}" : "DDE location #{DDE_LOCATION_ID}"
          Sidekiq.logger.info "No assigned DDE ID documents found for #{filter_msg}. Nothing to clean."
          return
        end
        
        filter_msg = location_id ? "location #{location_id}" : "DDE location #{DDE_LOCATION_ID}"
        Sidekiq.logger.info "Found #{assigned_docs.length} assigned DDE ID documents to delete for #{filter_msg}"
        
        # Use the base class bulk delete functionality
        docs_to_delete = assigned_docs.map do |row|
          {
            "_id" => row['id'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        delete_msg = location_id ? "assigned DDE IDs for location #{location_id}" : "assigned DDE IDs for DDE location #{DDE_LOCATION_ID}"
        perform_bulk_delete(couchdb_url(db_name), docs_to_delete, delete_msg)
        
      rescue => e
        error_msg = location_id ? "location #{location_id}" : "DDE location #{DDE_LOCATION_ID}"
        Sidekiq.logger.error "Error cleaning assigned DDE IDs for #{error_msg}: #{e.message}"
        raise e
      end
    end
    
    # Method to manually adjust target count if needed
    def self.set_target_count(new_target)
      remove_const(:TARGET_ID_COUNT) if const_defined?(:TARGET_ID_COUNT)
      const_set(:TARGET_ID_COUNT, new_target)
      Sidekiq.logger.info "DDE IDs target count updated to #{new_target} per facility"
    end
    
    # Helper method to get facility code by location (if needed)
    def get_facility_by_location(location_id)
      begin
        dde_facilities = get_dde_activated_facilities
        # This is a fallback method - you might need to implement location-to-facility mapping
        # For now, returns the first facility found (you may need to enhance this logic)
        dde_facilities.first
      rescue => e
        Sidekiq.logger.error "Error getting facility for location #{location_id}: #{e.message}"
        nil
      end
    end
    

    # Helper method to sync a specific facility
    def sync_specific_facility(location_id = 700, batch_size = 100)
      program_id = 14
      begin
        dde_service = DdeService.new(program: Program.find(program_id))
        process_facility_dde_sync(dde_service, location_id, 'dde', batch_size)
      rescue => e
        Sidekiq.logger.error "Error syncing facility #{location_id}: #{e.message}"
        raise e
      end
    end
  end
end

# Usage examples:
# Sync all DDE-activated facilities for default location (700):
# Sync::DdeIdsSyncJob.perform_async

# Sync all DDE-activated facilities for location 800:
# Sync::DdeIdsSyncJob.perform_async(800)

# Sync all DDE-activated facilities for location 700 with batch size 50:
# Sync::DdeIdsSyncJob.perform_async(700, 50)

# Sync a specific facility at a specific location:
# job = Sync::DdeIdsSyncJob.new
# job.sync_specific_facility('FAC001', 700, 50)

# To clean assigned IDs for a specific facility:
# job = Sync::DdeIdsSyncJob.new
# job.send(:clean_assigned_dde_ids, 'dde', 700, 'FAC001')

# To clean assigned IDs for entire location (all facilities):
# job = Sync::DdeIdsSyncJob.new
# job.send(:clean_assigned_dde_ids, 'dde', 700)

# To update existing documents with facility codes (migration helper):
# job = Sync::DdeIdsSyncJob.new
# job.send(:update_existing_documents_with_facility_codes, 'dde', 700)

# To change the target count per facility:
# Sync::DdeIdsSyncJob.set_target_count(100)  # Change target to 100 IDs per facility
