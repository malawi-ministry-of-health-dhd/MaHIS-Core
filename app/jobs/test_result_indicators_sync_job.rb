# app/jobs/test_result_indicators_sync_job.rb
class TestResultIndicatorsSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all test result indicators to CouchDB
  def perform(batch_size = 100) # Default batch size for indicators
    db_name = 'test_result_indicators'
    
    # Get test result indicators using the LabTestService
    test_indicators = LabTestService.all_test_result_indicators
    
    # Check record counts and clean CouchDB if they don't match
    return if check_and_clean_couchdb_if_needed(db_name, test_indicators) == :skip_sync
    
    total_count = test_indicators.length
    Sidekiq.logger.info "Starting sync of #{total_count} test result indicators to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    # Process in batches
    test_indicators.each_slice(batch_size).with_index do |indicator_batch, batch_index|
      indicator_batch.each_with_index do |indicator, index|
        begin
          sync_test_indicator_to_couchdb(indicator, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 10 records to prevent overwhelming CouchDB
          if (index + 1) % 10 == 0
            sleep(0.01) # 10ms delay
          end
          
          # Log progress every 50 records
          if processed % 50 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} test result indicators"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync test indicator concept ID #{indicator[:concept_id]}: #{e.message}"
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
          error_msg = "Failed to sync test indicator concept ID #{indicator[:concept_id]}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.05)
        end
      end
      
      # Longer pause between batches to give CouchDB time to process
      sleep(0.1)
      Sidekiq.logger.info "Completed batch #{batch_index + 1}. Processed #{processed}/#{total_count} test result indicators so far."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "Test result indicators sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def check_and_clean_couchdb_if_needed(db_name, test_indicators)
    begin
      mysql_count = test_indicators.length
      couchdb_count = get_couchdb_test_indicator_count(db_name)
      
      Sidekiq.logger.info "MySQL test indicator count: #{mysql_count}, CouchDB test indicator count: #{couchdb_count}"
      
      if mysql_count != couchdb_count
        Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
        Sidekiq.logger.info "Cleaning all test indicator records from CouchDB before sync..."
        
        delete_all_test_indicators_from_couchdb(db_name)
        
        Sidekiq.logger.info "Successfully cleaned all test indicator records from CouchDB"
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
  
  def get_couchdb_test_indicator_count(db_name)
    begin
      # Try to get the database info first
      db_url = "#{COUCHDB_URL}/#{db_name}"
      response = RestClient.get(db_url)
      db_info = JSON.parse(response.body)
      
      # Get count of test indicator documents specifically using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"test_indicator_"')
      end_key = URI.encode_www_form_component('"test_indicator_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      return result['total_rows'] || 0
      
    rescue RestClient::NotFound
      # Database doesn't exist, return 0
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      return 0
    rescue => e
      Sidekiq.logger.error "Error getting CouchDB test indicator count: #{e.message}"
      raise e
    end
  end
  
  def delete_all_test_indicators_from_couchdb(db_name)
    begin
      db_url = "#{COUCHDB_URL}/#{db_name}"
      
      # First, check if database exists
      begin
        RestClient.get(db_url)
      rescue RestClient::NotFound
        Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
        return
      end
      
      # Get all test indicator documents using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"test_indicator_"')
      end_key = URI.encode_www_form_component('"test_indicator_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      if result['rows'].empty?
        Sidekiq.logger.info "No test indicator documents found in CouchDB. Nothing to clean."
        return
      end
      
      Sidekiq.logger.info "Found #{result['rows'].length} test indicator documents to delete"
      
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
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} test indicator documents from CouchDB"
      
      # Log any errors
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
      
    rescue => e
      Sidekiq.logger.error "Error deleting test indicators from CouchDB: #{e.message}"
      raise e
    end
  end
  
  def sync_test_indicator_to_couchdb(indicator, db_name)
    doc_data = prepare_test_indicator_document(indicator)
    doc_id = "test_indicator_#{indicator[:concept_id]}_#{indicator[:concept_set]}"
    
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
  
  def prepare_test_indicator_document(indicator)
    {
      "type" => "test_result_indicator",
      "concept_id" => indicator[:concept_id],
      "name" => indicator[:name],
      "concept_set" => indicator[:concept_set],
      "synced_at" => Time.current.iso8601
    }
  end
end

# Usage examples:
# TestResultIndicatorsSyncJob.perform_async     # Default batch size of 100
# TestResultIndicatorsSyncJob.perform_async(50) # Smaller batches
# TestResultIndicatorsSyncJob.perform_async(25) # Even smaller batches for careful processing