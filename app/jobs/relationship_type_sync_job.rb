# app/jobs/relationship_type_sync_job.rb
class RelationshipTypeSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all relationship types to CouchDB
  def perform(batch_size = 50) # Small default batch size due to small dataset
    db_name = 'relationship'
    
    # Check record counts and clean CouchDB if they don't match
    return if check_and_clean_couchdb_if_needed(db_name) == :skip_sync
    
    total_count = RelationshipType.where(retired: false).count
    Sidekiq.logger.info "Starting sync of #{total_count} relationship types to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    RelationshipType.where(retired: false).find_in_batches(batch_size: batch_size) do |relationship_type_batch|
      relationship_type_batch.each_with_index do |relationship_type, index|
        begin
          sync_relationship_type_to_couchdb(relationship_type, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 5 records (small dataset)
          if (index + 1) % 5 == 0
            sleep(0.01) # 10ms delay
          end
          
          # Log progress every 10 records (small dataset, frequent logging)
          if processed % 10 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} relationship types"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync relationship type ID #{relationship_type.relationship_type_id}: #{e.message}"
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
          error_msg = "Failed to sync relationship type ID #{relationship_type.relationship_type_id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.05)
        end
      end
      
      # Shorter pause between batches due to small dataset
      sleep(0.05)
      Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} relationship types so far."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "RelationshipType sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def check_and_clean_couchdb_if_needed(db_name)
    begin
      mysql_count = RelationshipType.where(retired: false).count
      couchdb_count = get_couchdb_relationship_type_count(db_name)
      
      Sidekiq.logger.info "MySQL relationship type count: #{mysql_count}, CouchDB relationship type count: #{couchdb_count}"
      
      if mysql_count != couchdb_count
        Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
        Sidekiq.logger.info "Cleaning all relationship type records from CouchDB before sync..."
        
        delete_all_relationship_types_from_couchdb(db_name)
        
        Sidekiq.logger.info "Successfully cleaned all relationship type records from CouchDB"
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
  
  def get_couchdb_relationship_type_count(db_name)
    begin
      # Try to get the database info first
      db_url = "#{COUCHDB_URL}/#{db_name}"
      response = RestClient.get(db_url)
      db_info = JSON.parse(response.body)
      
      # Get count of relationship type documents specifically using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"relationship_type_"')
      end_key = URI.encode_www_form_component('"relationship_type_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      return result['total_rows'] || 0
      
    rescue RestClient::NotFound
      # Database doesn't exist, return 0
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      return 0
    rescue => e
      Sidekiq.logger.error "Error getting CouchDB relationship type count: #{e.message}"
      raise e
    end
  end
  
  def delete_all_relationship_types_from_couchdb(db_name)
    begin
      db_url = "#{COUCHDB_URL}/#{db_name}"
      
      # First, check if database exists
      begin
        RestClient.get(db_url)
      rescue RestClient::NotFound
        Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
        return
      end
      
      # Get all relationship type documents using URL encoding
      require 'uri'
      start_key = URI.encode_www_form_component('"relationship_type_"')
      end_key = URI.encode_www_form_component('"relationship_type_\ufff0"')
      
      view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
      response = RestClient.get(view_url)
      result = JSON.parse(response.body)
      
      if result['rows'].empty?
        Sidekiq.logger.info "No relationship type documents found in CouchDB. Nothing to clean."
        return
      end
      
      Sidekiq.logger.info "Found #{result['rows'].length} relationship type documents to delete"
      
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
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} relationship type documents from CouchDB"
      
      # Log any errors
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
      
    rescue => e
      Sidekiq.logger.error "Error deleting relationship types from CouchDB: #{e.message}"
      raise e
    end
  end
  
  def sync_relationship_type_to_couchdb(relationship_type, db_name)
    doc_data = prepare_relationship_type_document(relationship_type)
    doc_id = "relationship_type_#{relationship_type.relationship_type_id}"
    
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
  
  def prepare_relationship_type_document(relationship_type)
    {
      "type" => "relationship_type",
      "relationship_type_id" => relationship_type.relationship_type_id,
      "a_is_to_b" => relationship_type.a_is_to_b,
      "b_is_to_a" => relationship_type.b_is_to_a,
      "preferred" => relationship_type.preferred,
      "weight" => relationship_type.weight,
      "description" => relationship_type.description,
      "creator" => relationship_type.creator,
      "created_at" => relationship_type.date_created&.iso8601,
      "uuid" => relationship_type.uuid,
      "retired" => relationship_type.retired,
      "retired_by" => relationship_type.retired_by,
      "date_retired" => relationship_type.date_retired&.iso8601,
      "retire_reason" => relationship_type.retire_reason,
      "synced_at" => Time.current.iso8601
    }
  end
end

# Usage examples:
# RelationshipTypeSyncJob.perform_async(10)  # Small batches for testing
# RelationshipTypeSyncJob.perform_async(50)  # Default batch size
# RelationshipTypeSyncJob.perform_async      # Use default batch size