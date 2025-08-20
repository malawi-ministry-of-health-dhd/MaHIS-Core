# app/jobs/concept_name_sync_job.rb
class ConceptNameSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all concept names to CouchDB
  def perform(batch_size = 50) # Smaller default batch size due to large dataset
    db_name = 'concept_names'
    
    # Check record counts and clean CouchDB if they don't match
    return if check_and_clean_couchdb_if_needed(db_name) == :skip_sync
    
    total_count = ConceptName.where(voided: 0).count
    Sidekiq.logger.info "Starting sync of #{total_count} concept names to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    ConceptName.where(voided: 0).find_in_batches(batch_size: batch_size) do |concept_name_batch|
      concept_name_batch.each_with_index do |concept_name, index|
        begin
          sync_concept_name_to_couchdb(concept_name, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 5 records due to large dataset
          if (index + 1) % 5 == 0
            sleep(0.005) # 5ms delay - more frequent but shorter delays
          end
          
          # Log progress every 500 records due to large dataset
          if processed % 500 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} concept names (#{((processed.to_f/total_count)*100).round(1)}%)"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync concept name ID #{concept_name.concept_name_id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Progressive backoff for connection issues
          sleep_time = [0.1 * (2 ** [consecutive_errors - 1, 5].min), 5.0].min
          sleep(sleep_time)
          
          # If too many consecutive errors (likely connectivity issue), fail fast
          if consecutive_errors >= 5 # Reduced threshold
            raise "Too many consecutive connection errors (#{consecutive_errors}). Stopping sync. Last error: #{e.message}"
          end
          
        rescue => e
          # Handle other types of errors
          error_msg = "Failed to sync concept name ID #{concept_name.concept_name_id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.02) # Slightly longer delay for large dataset
        end
      end
      
      # Shorter pause between batches for large dataset efficiency
      sleep(0.05)
      Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} concept names so far (#{((processed.to_f/total_count)*100).round(1)}%)."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "Concept name sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def check_and_clean_couchdb_if_needed(db_name)
    begin
      mysql_count = ConceptName.where(voided: 0).count
      couchdb_count = get_couchdb_concept_name_count(db_name)
      
      Sidekiq.logger.info "MySQL concept name count: #{mysql_count}, CouchDB concept name count: #{couchdb_count}"
      
      if mysql_count != couchdb_count
        Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
        Sidekiq.logger.info "Cleaning all concept name records from CouchDB before sync..."
        
        delete_all_concept_names_from_couchdb(db_name)
        
        Sidekiq.logger.info "Successfully cleaned all concept name records from CouchDB"
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
  
  def get_couchdb_concept_name_count(db_name)
    begin
      # Try to get the database info first
      db_url = "#{COUCHDB_URL}/#{db_name}"
      response = RestClient.get(db_url)
      db_info = JSON.parse(response.body)
      
      # Get count of concept name documents specifically using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"concept_name_"')
      end_key = URI.encode_www_form_component('"concept_name_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      return result['total_rows'] || 0
      
    rescue RestClient::NotFound
      # Database doesn't exist, return 0
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      return 0
    rescue => e
      Sidekiq.logger.error "Error getting CouchDB concept name count: #{e.message}"
      raise e
    end
  end
  
  def delete_all_concept_names_from_couchdb(db_name)
    begin
      db_url = "#{COUCHDB_URL}/#{db_name}"
      
      # First, check if database exists
      begin
        RestClient.get(db_url)
      rescue RestClient::NotFound
        Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
        return
      end
      
      # Get all concept name documents using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"concept_name_"')
      end_key = URI.encode_www_form_component('"concept_name_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      if result['rows'].empty?
        Sidekiq.logger.info "No concept name documents found in CouchDB. Nothing to clean."
        return
      end
      
      Sidekiq.logger.info "Found #{result['rows'].length} concept name documents to delete"
      
      # For large datasets, delete in smaller batches to avoid timeout
      result['rows'].each_slice(1000) do |batch_rows|
        # Prepare bulk delete for this batch
        docs_to_delete = batch_rows.map do |row|
          {
            "_id" => row['id'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        # Perform bulk delete for this batch
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
        
        Sidekiq.logger.info "Successfully deleted #{successful_deletes} concept name documents from this batch"
        
        # Log any errors
        errors = delete_result.select { |result| result.key?('error') }
        if errors.any?
          Sidekiq.logger.error "Failed to delete #{errors.length} documents in this batch:"
          errors.first(5).each { |error| Sidekiq.logger.error "  #{error}" }
        end
        
        # Small delay between delete batches
        sleep(0.1)
      end
      
    rescue => e
      Sidekiq.logger.error "Error deleting concept names from CouchDB: #{e.message}"
      raise e
    end
  end
  
  def sync_concept_name_to_couchdb(concept_name, db_name)
    doc_data = prepare_concept_name_document(concept_name)
    doc_id = "concept_name_#{concept_name.concept_name_id}"
    
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
  
  def prepare_concept_name_document(concept_name)
    {
      "type" => "concept_name",
      "concept_name_id" => concept_name.concept_name_id,
      "concept_id" => concept_name.concept_id,
      "name" => concept_name.name,
      "locale" => concept_name.locale,
      "concept_name_type" => concept_name.concept_name_type,
      "locale_preferred" => concept_name.locale_preferred,
      "creator" => concept_name.creator,
      "voided" => concept_name.voided,
      "voided_by" => concept_name.voided_by,
      "void_reason" => concept_name.void_reason,
      "uuid" => concept_name.uuid,
      "date_created" => concept_name.date_created&.iso8601,
      "date_voided" => concept_name.date_voided&.iso8601,
      "synced_at" => Time.current.iso8601
    }
  end
end

# Usage examples:
# ConceptNameSyncJob.perform_async(25)  # Even smaller batches for large dataset
# ConceptNameSyncJob.perform_async     # Default batch size of 50