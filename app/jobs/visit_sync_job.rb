# app/jobs/visit_sync_job.rb
class VisitSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all visits to CouchDB
  def perform(batch_size = 50) # Smaller default batch size due to potentially larger visit records
    db_name = 'visits'
    
    # Check record counts and clean CouchDB if they don't match
    return if check_and_clean_couchdb_if_needed(db_name) == :skip_sync
    
    total_count = Visit.count
    Sidekiq.logger.info "Starting sync of #{total_count} visits to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    Visit.find_in_batches(batch_size: batch_size) do |visit_batch|
      visit_batch.each_with_index do |visit, index|
        begin
          sync_visit_to_couchdb(visit, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 10 records to prevent overwhelming CouchDB
          if (index + 1) % 10 == 0
            sleep(0.01) # 10ms delay
          end
          
          # Log progress every 25 records (smaller batches, so more frequent logging)
          if processed % 25 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} visits"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync visit ID #{visit.id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Progressive backoff for connection issues
          sleep_time = [0.1 * (2 ** [consecutive_errors - 1, 5].min), 5.0].min
          sleep(sleep_time)
          
          # If too many consecutive errors (likely connectivity issue), fail fast
          if consecutive_errors >= 5
            raise "Too many consecutive connection errors (#{consecutive_errors}). Stopping sync. Last error: #{e.message}"
          end
          
        rescue => e
          # Handle other types of errors
          error_msg = "Failed to sync visit ID #{visit.id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.05)
        end
      end
      
      # Longer pause between batches to give CouchDB time to process
      sleep(0.1)
      Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} visits so far."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "Visit sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def check_and_clean_couchdb_if_needed(db_name)
    begin
      mysql_count = Visit.count
      couchdb_count = get_couchdb_visit_count(db_name)
      
      Sidekiq.logger.info "MySQL visit count: #{mysql_count}, CouchDB visit count: #{couchdb_count}"
      
      if mysql_count != couchdb_count
        Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
        Sidekiq.logger.info "Cleaning all visit records from CouchDB before sync..."
        
        delete_all_visits_from_couchdb(db_name)
        
        Sidekiq.logger.info "Successfully cleaned all visit records from CouchDB"
        return :continue_sync
      else
        Sidekiq.logger.info "Record counts match. Skipping sync as data is already synchronized."
        return :skip_sync
      end
      
    rescue => e
      Sidekiq.logger.error "Error checking CouchDB record count: #{e.message}"
      Sidekiq.logger.info "Proceeding with sync despite count check failure..."
      return :continue_sync
    end
  end
  
  def get_couchdb_visit_count(db_name)
    begin
      # Try to get the database info first
      db_url = "#{COUCHDB_URL}/#{db_name}"
      response = RestClient.get(db_url)
      db_info = JSON.parse(response.body)
      
      # Get count of visit documents specifically using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"visit_"')
      end_key = URI.encode_www_form_component('"visit_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      return result['total_rows'] || 0
      
    rescue RestClient::NotFound
      # Database doesn't exist, return 0
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      return 0
    rescue => e
      Sidekiq.logger.error "Error getting CouchDB visit count: #{e.message}"
      raise e
    end
  end
  
  def delete_all_visits_from_couchdb(db_name)
    begin
      db_url = "#{COUCHDB_URL}/#{db_name}"
      
      # First, check if database exists
      begin
        RestClient.get(db_url)
      rescue RestClient::NotFound
        Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
        return
      end
      
      # Get all visit documents using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"visit_"')
      end_key = URI.encode_www_form_component('"visit_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      if result['rows'].empty?
        Sidekiq.logger.info "No visit documents found in CouchDB. Nothing to clean."
        return
      end
      
      Sidekiq.logger.info "Found #{result['rows'].length} visit documents to delete"
      
      # Prepare bulk delete
      docs_to_delete = result['rows'].map do |row|
        {
          "_id" => row['id'],
          "_rev" => row['doc']['_rev'],
          "_deleted" => true
        }
      end
      
      # Perform bulk delete
      bulk_url = "#{db_url}/_bulk_docs"
      bulk_data = {
        "docs" => docs_to_delete
      }
      
      delete_response = RestClient.post(
        bulk_url,
        bulk_data.to_json,
        { content_type: :json, accept: :json }
      )
      
      delete_result = JSON.parse(delete_response.body)
      successful_deletes = delete_result.count { |result| !result.key?('error') }
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} visit documents from CouchDB"
      
      # Log any errors
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
      
    rescue => e
      Sidekiq.logger.error "Error deleting visits from CouchDB: #{e.message}"
      raise e
    end
  end
  
  def sync_visit_to_couchdb(visit, db_name)
    doc_data = prepare_visit_document(visit)
    doc_id = "visit_#{visit.id}"
    
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
  
  def prepare_visit_document(visit)
    {
      "type" => "visit",
      "visit_id" => visit.id,
      "patient_id" => visit.patientId,
      "start_date" => visit.startDate&.iso8601,
      "closed_date_time" => visit.closedDateTime&.iso8601,
      "program_id" => visit.programId,
      "location_id" => visit.location_id,
      "created_at" => visit.created_at&.iso8601,
      "updated_at" => visit.updated_at&.iso8601,
      "synced_at" => Time.current.iso8601
    }
  end
end

# Usage examples:
# VisitSyncJob.perform_async(25)  # Smaller batches for testing
# VisitSyncJob.perform_async(50)  # Default batch size
# VisitSyncJob.perform_async(100) # Larger batches for faster sync