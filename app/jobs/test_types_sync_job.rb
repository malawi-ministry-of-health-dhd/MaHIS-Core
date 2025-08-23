# app/jobs/test_types_sync_job.rb
class TestTypesSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all test types to CouchDB
  def perform(batch_size = 50) # Smaller default batch size for test types
    db_name = 'test_types'
    
    # Get test types using the Lab service
    test_types = Lab::ConceptsService.test_types
    
    # Check record counts and clean CouchDB if they don't match
    return if check_and_clean_couchdb_if_needed(db_name, test_types) == :skip_sync
    
    total_count = test_types.length
    Sidekiq.logger.info "Starting sync of #{total_count} test types to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    # Process in batches
    test_types.each_slice(batch_size).with_index do |test_batch, batch_index|
      test_batch.each_with_index do |test_type, index|
        begin
          sync_test_type_to_couchdb(test_type, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 5 records to prevent overwhelming CouchDB
          if (index + 1) % 5 == 0
            sleep(0.01) # 10ms delay
          end
          
          # Log progress every 25 records (smaller intervals for test types)
          if processed % 25 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} test types"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync test type concept ID #{test_type.concept_id}: #{e.message}"
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
          error_msg = "Failed to sync test type concept ID #{test_type.concept_id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.05)
        end
      end
      
      # Longer pause between batches to give CouchDB time to process
      sleep(0.1)
      Sidekiq.logger.info "Completed batch #{batch_index + 1}. Processed #{processed}/#{total_count} test types so far."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "Test types sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def check_and_clean_couchdb_if_needed(db_name, test_types)
    begin
      mysql_count = test_types.length
      couchdb_count = get_couchdb_test_type_count(db_name)
      
      Sidekiq.logger.info "MySQL test type count: #{mysql_count}, CouchDB test type count: #{couchdb_count}"
      
      if mysql_count != couchdb_count
        Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
        Sidekiq.logger.info "Cleaning all test type records from CouchDB before sync..."
        
        delete_all_test_types_from_couchdb(db_name)
        
        Sidekiq.logger.info "Successfully cleaned all test type records from CouchDB"
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
  
  def get_couchdb_test_type_count(db_name)
    begin
      # Try to get the database info first
      db_url = "#{COUCHDB_URL}/#{db_name}"
      response = RestClient.get(db_url)
      db_info = JSON.parse(response.body)
      
      # Get count of test type documents specifically using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"test_type_"')
      end_key = URI.encode_www_form_component('"test_type_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      return result['total_rows'] || 0
      
    rescue RestClient::NotFound
      # Database doesn't exist, return 0
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      return 0
    rescue => e
      Sidekiq.logger.error "Error getting CouchDB test type count: #{e.message}"
      raise e
    end
  end
  
  def delete_all_test_types_from_couchdb(db_name)
    begin
      db_url = "#{COUCHDB_URL}/#{db_name}"
      
      # First, check if database exists
      begin
        RestClient.get(db_url)
      rescue RestClient::NotFound
        Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
        return
      end
      
      # Get all test type documents using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"test_type_"')
      end_key = URI.encode_www_form_component('"test_type_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      if result['rows'].empty?
        Sidekiq.logger.info "No test type documents found in CouchDB. Nothing to clean."
        return
      end
      
      Sidekiq.logger.info "Found #{result['rows'].length} test type documents to delete"
      
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
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} test type documents from CouchDB"
      
      # Log any errors
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
      
    rescue => e
      Sidekiq.logger.error "Error deleting test types from CouchDB: #{e.message}"
      raise e
    end
  end
  
  def sync_test_type_to_couchdb(test_type, db_name)
    doc_data = prepare_test_type_document(test_type)
    doc_id = "test_type_#{test_type.concept_id}"
    
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
  
  def prepare_test_type_document(test_type)
    {
      "type" => "test_type",
      "concept_id" => test_type.concept_id,
      "name" => test_type.name,
      "concept_set_id" => test_type.concept_set_id,
      "synced_at" => Time.current.iso8601
    }
  end
end

# Usage examples:
# TestTypesSyncJob.perform_async     # Default batch size of 50
# TestTypesSyncJob.perform_async(25) # Smaller batches
# TestTypesSyncJob.perform_async(10) # Very small batches for careful processing