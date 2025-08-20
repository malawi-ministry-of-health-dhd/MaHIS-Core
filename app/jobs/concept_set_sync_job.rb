# app/jobs/concept_set_sync_job.rb
class ConceptSetSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all concept sets to CouchDB
  def perform(batch_size = 100) # Default batch size
    db_name = 'concept_sets'
    
    # Check record counts and clean CouchDB if they don't match
    return if check_and_clean_couchdb_if_needed(db_name) == :skip_sync
    
    concept_sets = get_concept_sets_data
    total_count = concept_sets.count
    Sidekiq.logger.info "Starting sync of #{total_count} concept sets to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    concept_sets.each_slice(batch_size).with_index do |concept_set_batch, batch_index|
      concept_set_batch.each_with_index do |concept_set_data, index|
        begin
          sync_concept_set_to_couchdb(concept_set_data, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 10 records to prevent overwhelming CouchDB
          if (index + 1) % 10 == 0
            sleep(0.01) # 10ms delay
          end
          
          # Log progress every 50 records
          if processed % 50 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} concept sets"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync concept set ID #{concept_set_data[:id]}: #{e.message}"
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
          error_msg = "Failed to sync concept set ID #{concept_set_data[:id]}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.05)
        end
      end
      
      # Pause between batches to give CouchDB time to process
      sleep(0.1)
      Sidekiq.logger.info "Completed batch #{batch_index + 1}. Processed #{processed}/#{total_count} concept sets so far."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "ConceptSet sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def get_concept_sets_data
    # Set the group_concat_max_len to handle large concatenated strings
    ActiveRecord::Base.connection.execute("SET SESSION group_concat_max_len = 1000000")
    
    concept_sets = ConceptName
      .select("concept_name.name AS concept_set_name,
               concept_name.concept_id AS concept_set_id, 
               COALESCE(GROUP_CONCAT(DISTINCT concept_set.concept_id), '') AS member_ids")
      .joins("JOIN concept_set ON concept_name.concept_id = concept_set.concept_set")
      .where(voided: 0)
      .group("concept_name.concept_id")
      .order("concept_name.name")
    
    # Transform the data to match the expected format
    concept_sets.map do |result|
      member_ids = result.member_ids.present? ? result.member_ids.split(",").map(&:to_i) : []
      {
        id: result.concept_set_id,
        concept_set_name: result.concept_set_name,
        member_ids: member_ids
      }
    end
  end
  
  def check_and_clean_couchdb_if_needed(db_name)
    begin
      mysql_count = get_mysql_concept_set_count
      couchdb_count = get_couchdb_concept_set_count(db_name)
      
      Sidekiq.logger.info "MySQL concept set count: #{mysql_count}, CouchDB concept set count: #{couchdb_count}"
      
      if mysql_count != couchdb_count
        Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
        Sidekiq.logger.info "Cleaning all concept set records from CouchDB before sync..."
        
        delete_all_concept_sets_from_couchdb(db_name)
        
        Sidekiq.logger.info "Successfully cleaned all concept set records from CouchDB"
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
  
  def get_mysql_concept_set_count
    ActiveRecord::Base.connection.execute("SET SESSION group_concat_max_len = 1000000")
    
    ConceptName
      .joins("JOIN concept_set ON concept_name.concept_id = concept_set.concept_set")
      .where(voided: 0)
      .group("concept_name.concept_id")
      .count.length
  end
  
  def get_couchdb_concept_set_count(db_name)
    begin
      # Try to get the database info first
      db_url = "#{COUCHDB_URL}/#{db_name}"
      response = RestClient.get(db_url)
      db_info = JSON.parse(response.body)
      
      # Get count of concept set documents specifically using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"concept_set_"')
      end_key = URI.encode_www_form_component('"concept_set_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      return result['total_rows'] || 0
      
    rescue RestClient::NotFound
      # Database doesn't exist, return 0
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      return 0
    rescue => e
      Sidekiq.logger.error "Error getting CouchDB concept set count: #{e.message}"
      raise e
    end
  end
  
  def delete_all_concept_sets_from_couchdb(db_name)
    begin
      db_url = "#{COUCHDB_URL}/#{db_name}"
      
      # First, check if database exists
      begin
        RestClient.get(db_url)
      rescue RestClient::NotFound
        Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
        return
      end
      
      # Get all concept set documents using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"concept_set_"')
      end_key = URI.encode_www_form_component('"concept_set_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      if result['rows'].empty?
        Sidekiq.logger.info "No concept set documents found in CouchDB. Nothing to clean."
        return
      end
      
      Sidekiq.logger.info "Found #{result['rows'].length} concept set documents to delete"
      
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
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} concept set documents from CouchDB"
      
      # Log any errors
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
      
    rescue => e
      Sidekiq.logger.error "Error deleting concept sets from CouchDB: #{e.message}"
      raise e
    end
  end
  
  def sync_concept_set_to_couchdb(concept_set_data, db_name)
    doc_data = prepare_concept_set_document(concept_set_data)
    doc_id = "concept_set_#{concept_set_data[:id]}"
    
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
  
  def prepare_concept_set_document(concept_set_data)
    {
      "type" => "concept_set",
      "concept_set_id" => concept_set_data[:id],
      "concept_set_name" => concept_set_data[:concept_set_name],
      "member_ids" => concept_set_data[:member_ids],
      "member_count" => concept_set_data[:member_ids].length,
      "synced_at" => Time.current.iso8601
    }
  end
end

# Usage examples:
# ConceptSetSyncJob.perform_async(50)   # Smaller batches for testing
# ConceptSetSyncJob.perform_async(100)  # Default batch size
# ConceptSetSyncJob.perform_async(200)  # Larger batches for faster sync