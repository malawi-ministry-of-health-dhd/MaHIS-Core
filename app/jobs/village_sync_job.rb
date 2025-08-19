# app/jobs/village_sync_job.rb
class VillageSyncJob
  include Sidekiq::Job
  include CouchdbSync
  
  sidekiq_options queue: 'sync_offline_data', retry: 3
  
  # Sync all villages to CouchDB
  def perform(batch_size = 100) # Reduced default batch size
    db_name = 'villages'
    
    total_count = Village.where(retired: false).count
    Sidekiq.logger.info "Starting sync of #{total_count} villages to CouchDB at #{COUCHDB_URL}"
    
    processed = 0
    errors = []
    consecutive_errors = 0
    
    Village.where(retired: false).find_in_batches(batch_size: batch_size) do |village_batch|
      village_batch.each_with_index do |village, index|
        begin
          sync_village_to_couchdb(village, db_name)
          processed += 1
          consecutive_errors = 0 # Reset consecutive error counter on success
          
          # Rate limiting: Add a small delay every 10 records to prevent overwhelming CouchDB
          if (index + 1) % 10 == 0
            sleep(0.01) # 10ms delay
          end
          
          # Log progress every 100 records
          if processed % 100 == 0
            Sidekiq.logger.info "Synced #{processed}/#{total_count} villages"
          end
          
        rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
          consecutive_errors += 1
          error_msg = "Failed to sync village ID #{village.id}: #{e.message}"
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
          error_msg = "Failed to sync village ID #{village.id}: #{e.message}"
          Sidekiq.logger.error error_msg
          errors << error_msg
          
          # Don't count non-connection errors toward consecutive failures
          # but still add a small delay
          sleep(0.05)
        end
      end
      
      # Longer pause between batches to give CouchDB time to process
      sleep(0.1)
      Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} villages so far."
    end
    
    # Final summary
    success_count = processed - errors.length
    Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
    
    if errors.any?
      Sidekiq.logger.error "Total errors: #{errors.length}"
      # Only fail if error rate is very high
      if errors.length > total_count * 0.05 # Fail if >5% error rate
        raise "Village sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{(errors.length.to_f/total_count*100).round(2)}%)"
      end
    end
  end
  
  private
  
  def sync_village_to_couchdb(village, db_name)
    doc_data = prepare_village_document(village)
    doc_id = "village_#{village.id}"
    
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
  
  def prepare_village_document(village)
    {
      "type" => "village",
      "village_id" => village.village_id,
      "name" => village.name,
      "created_at" => village.date_created&.iso8601,
      "retired" => village.retired,
      "synced_at" => Time.current.iso8601
    }
  end
end



# Usage examples:

# VillageSyncJob.perform_async(50)  # Even smaller batches

