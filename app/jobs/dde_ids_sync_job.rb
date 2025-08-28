# app/jobs/dde_ids_sync_job.rb
class DdeIdsSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
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
    
    Sidekiq.logger.info "Starting sync of DDE IDs for location #{location_id} to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    total_allocated = 0
    
    # Allocate IDs in batches and sync them
    begin
      loop do
        begin
          # Request batch of IDs from DDE service
          Sidekiq.logger.info "Requesting #{batch_size} DDE IDs for location #{location_id}"
          response = dde_service.allocate_npids(batch_size, location_id)
          
          if response['npids'].nil? || response['npids'].empty?
            Sidekiq.logger.info "No more DDE IDs available for allocation. Sync completed."
            break
          end
          
          npids = response['npids']
          Sidekiq.logger.info "Received #{npids.length} DDE IDs to sync"
          
          # Sync each ID to CouchDB
          npids.each_with_index do |npid_data, index|
            begin
              sync_dde_id_to_couchdb(npid_data, db_name)
              processed += 1
              consecutive_errors = 0 # Reset consecutive error counter on success
              
              # Rate limiting: Add a small delay every 10 records
              if (index + 1) % 10 == 0
                sleep(0.01) # 10ms delay
              end
              
              # Log progress every 50 records (smaller batches)
              if processed % 50 == 0
                Sidekiq.logger.info "Synced #{processed} DDE IDs so far"
              end
              
            rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
              consecutive_errors += 1
              error_msg = "Failed to sync DDE ID #{npid_data['npid']} : #{e.message}"
              Sidekiq.logger.error error_msg
              errors << error_msg
              
              # Progressive backoff for connection issues
              sleep_time = [0.1 * (2 ** [consecutive_errors - 1, 5].min), 5.0].min
              sleep(sleep_time)
              
              # If too many consecutive errors, fail fast
              if consecutive_errors >= 5
                raise "Too many consecutive connection errors (#{consecutive_errors}). Stopping sync. Last error: #{e.message}"
              end
              
            rescue => e
              # Handle other types of errors
              error_msg = "Failed to sync DDE ID #{npid_data['npid']} : #{e.message}"
              Sidekiq.logger.error error_msg
              errors << error_msg
              
              # Don't count non-connection errors toward consecutive failures
              sleep(0.05)
            end
          end
          
          total_allocated += npids.length
          
          # Pause between DDE service calls to avoid overwhelming the service
          sleep(0.5)
          Sidekiq.logger.info "Completed batch. Processed #{processed} DDE IDs, allocated #{total_allocated} total."
          
        rescue => e
          Sidekiq.logger.error "Error requesting DDE IDs: #{e.message}"
          # Break the loop if we can't get IDs from DDE service
          break
        end
        
        # Safety check to prevent infinite loops
        if total_allocated >= 10000 # Adjust limit as needed
          Sidekiq.logger.warn "Reached allocation limit (#{total_allocated}). Stopping sync."
          break
        end
      end
      
    rescue => e
      Sidekiq.logger.error "Fatal error during DDE sync: #{e.message}"
      raise e
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "DDE sync completed: #{success_count} successful, #{errors.length} errors, #{total_allocated} total allocated"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > processed * 0.1 # Fail if >10% error rate (more lenient for external service)
        raise "DDE sync completed with unacceptable error rate: #{errors.length}/#{processed} (#{(errors.length.to_f/processed*100).round(2)}%)"
      end
    end
  end
  
  private
  
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
  
  def sync_dde_id_to_couchdb(npid_data, db_name)
    doc_data = prepare_dde_id_document(npid_data)
    doc_id = npid_data['npid']
    
    # Add timeout and retry logic specifically for sync
    retries = 0
    begin
      sync_to_couchdb(doc_data, db_name, doc_id)
    rescue RestClient::Exception, SocketError => e
      retries += 1
      if retries <= 2 # Retry up to 2 times for connection issues
        sleep(0.1 * retries) # Progressive delay
        retry
      else
        raise e
      end
    end
  end
  
  def prepare_dde_id_document(npid_data)
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
      
      # Prepare bulk delete
      docs_to_delete = assigned_docs.map do |row|
        {
          "_id" => row['npid'],
          "_rev" => row['doc']['_rev'],
          "_deleted" => true
        }
      end
      
      # Perform bulk delete
      bulk_url = "#{db_url}/_bulk_docs"
      bulk_data = { "docs" => docs_to_delete }
      
      delete_response = RestClient.post(
        bulk_url,
        bulk_data.to_json,
        { content_type: :json, accept: :json }
      )
      
      delete_result = JSON.parse(delete_response.body)
      successful_deletes = delete_result.count { |result| !result.key?('error') }
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} assigned DDE ID documents from CouchDB"
      
    rescue => e
      Sidekiq.logger.error "Error cleaning assigned DDE IDs from CouchDB: #{e.message}"
      raise e
    end
  end
end

# Usage examples:
# DdeIdsSyncJob.perform_async(700, 50)  # Sync for location 700 with batch size 50
# DdeIdsSyncJob.perform_async(700)      # Sync for location 700 with default batch size 100

# To clean assigned IDs and force resync:
# job = DdeIdsSyncJob.new
# job.send(:clean_assigned_dde_ids, 'dde_ids', 700)