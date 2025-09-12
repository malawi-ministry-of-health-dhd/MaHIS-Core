# app/jobs/sync/base_sync_job.rb
module Sync
  class BaseSyncJob
    include Sidekiq::Job
    include CouchdbSync
    
    sidekiq_options queue: 'sync_offline_data', retry: 3
    
    # Abstract method - must be implemented by subclasses
    def perform(batch_size = 100)
      raise NotImplementedError, "Subclasses must implement the perform method"
    end
    
    protected
    
  # Generic sync method that handles the common sync logic for model-based records
    def sync_records_to_couchdb(model_class, db_name, batch_size = 100, &record_filter)
      # Use the provided filter or default to non-retired records
      query = record_filter ? record_filter.call(model_class) : default_filter(model_class)
      
      # Check record counts and clean CouchDB if they don't match
      return if check_and_clean_couchdb_if_needed_for_model(model_class, db_name, query) == :skip_sync
      
      total_count = query.count
      model_name = model_class.name.downcase
      
      Sidekiq.logger.info "Starting sync of #{total_count} #{model_name.pluralize} to CouchDB at #{COUCHDB_URL}"
      
      processed = 0
      skipped = 0
      errors = []
      consecutive_errors = 0
      
      query.find_in_batches(batch_size: batch_size) do |batch|
        batch.each_with_index do |record, index|
          begin
            result = sync_record_to_couchdb(record, db_name)
            if result == :skipped
              skipped += 1
            else
              processed += 1
            end
            consecutive_errors = 0 # Reset consecutive error counter on success
            
            # Rate limiting: Add a small delay every 10 records
            add_rate_limiting_delay(index)
            
            # Log progress every 100 records
            log_progress(processed, total_count, model_name.pluralize, skipped)
            
          rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
            consecutive_errors = handle_connection_error(record, e, consecutive_errors, errors)
            
          rescue => e
            handle_general_error(record, e, errors)
          end
        end
        
        # Longer pause between batches
        sleep(0.1)
        Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} #{model_name.pluralize} so far. Skipped: #{skipped}"
      end
      
      # Final summary and error handling
      handle_sync_completion(processed, errors, total_count, model_name, skipped)
    end
    
    # Generic sync method for custom queries (like complex joins)
    def sync_custom_query_to_couchdb(query, count_query, db_name, data_type_name, batch_size = 50, progress_interval: 25, rate_limit_interval: 10)
      # Check record counts and clean CouchDB if they don't match
      return if check_and_clean_couchdb_if_needed_for_custom(count_query, db_name, data_type_name) == :skip_sync
      
      total_count = count_query.count
      
      Sidekiq.logger.info "Starting sync of #{total_count} #{data_type_name.pluralize} to CouchDB at #{COUCHDB_URL}"
      
      processed = 0
      errors = []
      consecutive_errors = 0
      
      query.find_in_batches(batch_size: batch_size) do |batch|
        batch.each_with_index do |record, index|
          begin
            sync_record_to_couchdb(record, db_name)
            processed += 1
            consecutive_errors = 0 # Reset consecutive error counter on success
            
            # Rate limiting with configurable interval
            if (index + 1) % rate_limit_interval == 0
              sleep(0.01) # 10ms delay
            end
            
            # Log progress with configurable interval
            if processed % progress_interval == 0
              Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"
            end
            
          rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
            consecutive_errors = handle_connection_error(record, e, consecutive_errors, errors)
            
          rescue => e
            handle_general_error(record, e, errors)
          end
        end
        
        # Longer pause between batches
        sleep(0.1)
        Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} #{data_type_name.pluralize} so far."
      end
      
      # Final summary and error handling
      handle_sync_completion(processed, errors, total_count, data_type_name)
    end
    # Generic sync method for array-based data (like service results)
    def sync_array_to_couchdb(data_array, db_name, data_type_name, batch_size = 50, progress_interval: 25, rate_limit_interval: 5)
      # Check record counts and clean CouchDB if they don't match
      return if check_and_clean_couchdb_if_needed_for_array(data_array, db_name, data_type_name) == :skip_sync
      
      total_count = data_array.length
      
      Sidekiq.logger.info "Starting sync of #{total_count} #{data_type_name.pluralize} to CouchDB at #{COUCHDB_URL}"
      
      processed = 0
      errors = []
      consecutive_errors = 0
      
      # Process in batches using each_slice
      data_array.each_slice(batch_size).with_index do |batch, batch_index|
        batch.each_with_index do |record, index|
          begin
            sync_record_to_couchdb(record, db_name)
            processed += 1
            consecutive_errors = 0 # Reset consecutive error counter on success
            
            # Rate limiting with configurable interval
            if (index + 1) % rate_limit_interval == 0
              sleep(0.01) # 10ms delay
            end
            
            # Log progress with configurable interval
            if processed % progress_interval == 0
              Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"
            end
            
          rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
            consecutive_errors = handle_connection_error(record, e, consecutive_errors, errors)
            
          rescue => e
            handle_general_error(record, e, errors)
          end
        end
        
        # Longer pause between batches
        sleep(0.1)
        Sidekiq.logger.info "Completed batch #{batch_index + 1}. Processed #{processed}/#{total_count} #{data_type_name.pluralize} so far."
      end
      
      # Final summary and error handling
      handle_sync_completion(processed, errors, total_count, data_type_name)
    end
    
    # Generic count check and cleanup method for model-based sync
    def check_and_clean_couchdb_if_needed_for_model(model_class, db_name, query)
      begin
        mysql_count = query.count
        couchdb_count = get_couchdb_record_count(db_name, get_document_prefix(model_class))
        model_name = model_class.name.downcase
        
        Sidekiq.logger.info "MySQL #{model_name} count: #{mysql_count}, CouchDB #{model_name} count: #{couchdb_count}"
        
        if mysql_count != couchdb_count
          Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
          Sidekiq.logger.info "Cleaning all #{model_name} records from CouchDB before sync..."
          
          delete_all_records_from_couchdb(db_name, get_document_prefix(model_class), model_name)
          
          Sidekiq.logger.info "Successfully cleaned all #{model_name} records from CouchDB"
          return :continue_sync
        else
          Sidekiq.logger.info "Record counts match. Skipping sync as data is already synchronized."
          return :skip_sync
        end
        
      rescue => e
        model_name = model_class.name.downcase
        Sidekiq.logger.error "Error checking CouchDB record count: #{e.message}"
        Sidekiq.logger.info "Proceeding with sync despite count check failure..."
        return :continue_sync
      end
    end
    
    # Generic count check and cleanup method for custom query sync
    def check_and_clean_couchdb_if_needed_for_custom(count_query, db_name, data_type_name)
      begin
        source_count = count_query.count
        couchdb_count = get_couchdb_type_count(db_name, data_type_name.downcase.singularize)
        
        Sidekiq.logger.info "Source #{data_type_name} count: #{source_count}, CouchDB #{data_type_name} count: #{couchdb_count}"
        
        if source_count != couchdb_count
          Sidekiq.logger.warn "Record count mismatch detected! Source: #{source_count}, CouchDB: #{couchdb_count}"
          Sidekiq.logger.info "Cleaning all #{data_type_name} records from CouchDB before sync..."
          
          delete_all_records_by_type_from_couchdb(db_name, data_type_name.downcase.singularize, data_type_name)
          
          Sidekiq.logger.info "Successfully cleaned all #{data_type_name} records from CouchDB"
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
    # Generic count check and cleanup method for array-based sync
    def check_and_clean_couchdb_if_needed_for_array(data_array, db_name, data_type_name)
      begin
        source_count = data_array.length
        document_prefix = "#{data_type_name.downcase.singularize}_"
        couchdb_count = get_couchdb_record_count(db_name, document_prefix)
        
        Sidekiq.logger.info "Source #{data_type_name} count: #{source_count}, CouchDB #{data_type_name} count: #{couchdb_count}"
        
        if source_count != couchdb_count
          Sidekiq.logger.warn "Record count mismatch detected! Source: #{source_count}, CouchDB: #{couchdb_count}"
          Sidekiq.logger.info "Cleaning all #{data_type_name} records from CouchDB before sync..."
          
          delete_all_records_from_couchdb(db_name, document_prefix, data_type_name)
          
          Sidekiq.logger.info "Successfully cleaned all #{data_type_name} records from CouchDB"
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
    
    # Generic CouchDB record count method
    def get_couchdb_record_count(db_name, document_prefix)
      begin
        db_url = "#{COUCHDB_URL}/#{db_name}"
        response = RestClient.get(db_url)
        db_info = JSON.parse(response.body)
        
        # Get count of specific documents using URL encoding
        require 'uri'
        start_key = URI.encode_www_form_component("\"#{document_prefix}\"")
        end_key = URI.encode_www_form_component("\"#{document_prefix}\\ufff0\"")
        
        view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        return result['total_rows'] || 0
        
      rescue RestClient::NotFound
        Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
        return 0
      rescue => e
        Sidekiq.logger.error "Error getting CouchDB record count: #{e.message}"
        raise e
      end
    end
    
    # Get count of documents by type (for documents that don't use prefix-based IDs)
    def get_couchdb_type_count(db_name, document_type)
      begin
        db_url = "#{COUCHDB_URL}/#{db_name}"
        response = RestClient.get(db_url)
        db_info = JSON.parse(response.body)
        
        # Get all documents and count by type
        view_url = "#{db_url}/_all_docs"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        # Count documents by checking their type
        type_count = 0
        result['rows'].each do |row|
          next if row['id'].start_with?('_design')
          
          # Get the document to check its type
          begin
            doc_response = RestClient.get("#{db_url}/#{row['id']}")
            doc = JSON.parse(doc_response.body)
            type_count += 1 if doc['type'] == document_type
          rescue => e
            # Skip if we can't read the document
            Sidekiq.logger.warn "Couldn't read document #{row['id']}: #{e.message}"
          end
        end
        
        return type_count
        
      rescue RestClient::NotFound
        Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
        return 0
      rescue => e
        Sidekiq.logger.error "Error getting CouchDB #{document_type} count: #{e.message}"
        raise e
      end
    end
    
    # Delete documents by type (for documents that don't use prefix-based IDs)
    def delete_all_records_by_type_from_couchdb(db_name, document_type, model_name)
      begin
        db_url = "#{COUCHDB_URL}/#{db_name}"
        
        # Check if database exists
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
          return
        end
        
        # Get all documents and filter by type
        view_url = "#{db_url}/_all_docs?include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        # Filter for documents of the specified type
        type_docs = result['rows'].select do |row|
          !row['id'].start_with?('_design') && row['doc'] && row['doc']['type'] == document_type
        end
        
        if type_docs.empty?
          Sidekiq.logger.info "No #{model_name} documents found in CouchDB. Nothing to clean."
          return
        end
        
        Sidekiq.logger.info "Found #{type_docs.length} #{model_name} documents to delete"
        
        # Prepare bulk delete
        docs_to_delete = type_docs.map do |row|
          {
            "_id" => row['id'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        # Perform bulk delete
        perform_bulk_delete(db_url, docs_to_delete, model_name)
        
      rescue => e
        Sidekiq.logger.error "Error deleting #{model_name.pluralize} from CouchDB: #{e.message}"
        raise e
      end
    end
    # Generic bulk delete method for prefix-based documents
    def delete_all_records_from_couchdb(db_name, document_prefix, model_name)
      begin
        db_url = "#{COUCHDB_URL}/#{db_name}"
        
        # Check if database exists
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
          return
        end
        
        # Get all documents with the specific prefix
        require 'uri'
        start_key = URI.encode_www_form_component("\"#{document_prefix}\"")
        end_key = URI.encode_www_form_component("\"#{document_prefix}\\ufff0\"")
        
        view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}&include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        if result['rows'].empty?
          Sidekiq.logger.info "No #{model_name} documents found in CouchDB. Nothing to clean."
          return
        end
        
        Sidekiq.logger.info "Found #{result['rows'].length} #{model_name} documents to delete"
        
        # Prepare bulk delete
        docs_to_delete = result['rows'].map do |row|
          {
            "_id" => row['id'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        # Perform bulk delete
        perform_bulk_delete(db_url, docs_to_delete, model_name)
        
      rescue => e
        Sidekiq.logger.error "Error deleting #{model_name.pluralize} from CouchDB: #{e.message}"
        raise e
      end
    end
    
    # Generic sync individual record method
    def sync_record_to_couchdb(record, db_name)
      doc_data = prepare_document(record)
      doc_id = generate_document_id(record)
      
      retries = 0
      begin
        sync_to_couchdb(doc_data, db_name, doc_id)
      rescue RestClient::Exception, SocketError => e
        retries += 1
        if retries <= 2
          sleep(0.1 * retries) # Progressive delay
          retry
        else
          raise e
        end
      end
    end
    
    private
    
    # Default filter for non-retired records (works for most models)
    def default_filter(model_class)
      if model_class.column_names.include?('retired')
        model_class.where(retired: [0, false])
      else
        model_class.all
      end
    end
    
    # Get document prefix based on model class
    def get_document_prefix(model_class)
      "#{model_class.name.downcase}_"
    end
    
    # Rate limiting delay
    def add_rate_limiting_delay(index)
      if (index + 1) % 10 == 0
        sleep(0.01) # 10ms delay
      end
    end
    
    # Progress logging
   def log_progress(processed, total_count, model_name, skipped = 0)
    if processed % 100 == 0
      if skipped > 0
        Sidekiq.logger.info "Synced #{processed}/#{total_count} #{model_name} (skipped: #{skipped})"
      else
        Sidekiq.logger.info "Synced #{processed}/#{total_count} #{model_name}"
      end
    end
  end
    
    # Handle connection errors with progressive backoff
    def handle_connection_error(record, error, consecutive_errors, errors)
      consecutive_errors += 1
      record_id = get_record_identifier(record)
      error_msg = "Failed to sync #{record.class.name.downcase} ID #{record_id}: #{error.message}"
      Sidekiq.logger.error error_msg
      errors << error_msg
      
      # Progressive backoff
      sleep_time = [0.1 * (2 ** [consecutive_errors - 1, 5].min), 5.0].min
      sleep(sleep_time)
      
      # Fail fast on too many consecutive errors
      if consecutive_errors >= 5
        raise "Too many consecutive connection errors (#{consecutive_errors}). Stopping sync. Last error: #{error.message}"
      end
      
      consecutive_errors
    end
    
    # Handle general errors
    def handle_general_error(record, error, errors)
      record_id = get_record_identifier(record)
      record_type = record.respond_to?(:class) ? record.class.name.downcase : 'record'
      error_msg = "Failed to sync #{record_type} ID #{record_id}: #{error.message}"
      Sidekiq.logger.error error_msg
      errors << error_msg
      sleep(0.05)
    end
    
    # Final sync completion handling
    def handle_sync_completion(processed, errors, total_count, model_name)
      success_count = processed - errors.length
      Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
      
      if errors.any?
        Sidekiq.logger.error "Total errors: #{errors.length}"
        if errors.length > total_count * 0.05 # Fail if >5% error rate
          error_rate = (errors.length.to_f/total_count*100).round(2)
          raise "#{model_name.capitalize} sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{error_rate}%)"
        end
      end
    end
    
    # Bulk delete operation
    def perform_bulk_delete(db_url, docs_to_delete, model_name)
      bulk_url = "#{db_url}/_bulk_docs"
      bulk_data = { "docs" => docs_to_delete }
      
      delete_response = RestClient.post(
        bulk_url,
        bulk_data.to_json,
        { content_type: :json, accept: :json }
      )
      
      delete_result = JSON.parse(delete_response.body)
      successful_deletes = delete_result.count { |result| !result.key?('error') }
      
      Sidekiq.logger.info "Successfully deleted #{successful_deletes} #{model_name} documents from CouchDB"
      
      # Log any errors
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
    end
    
    # Get record identifier (tries common ID fields)
    def get_record_identifier(record)
      %w[drug_id village_id id].each do |field|
        return record.send(field) if record.respond_to?(field)
      end
      record.id
    end
    
    # Abstract methods that must be implemented by subclasses
    def prepare_document(record)
      raise NotImplementedError, "Subclasses must implement prepare_document method"
    end
    
    def generate_document_id(record)
      raise NotImplementedError, "Subclasses must implement generate_document_id method"
    end
  end
end