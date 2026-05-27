# app/jobs/sync/base_sync_job.rb
module Sync
  class BaseSyncJob
    include Sidekiq::Job
    include CouchdbSync
    
    sidekiq_options queue: 'sync_offline_data', retry: 3
    
    # Configuration - can be overridden in subclasses
    BULK_SYNC_ENABLED = true
    DEFAULT_BULK_BATCH_SIZE = 5000
    
    # Abstract method - must be implemented by subclasses
    def perform(batch_size = DEFAULT_BULK_BATCH_SIZE)
      raise NotImplementedError, "Subclasses must implement the perform method"
    end
    
    protected
    
    # Enhanced sync method with automatic bulk operations
    def sync_records_to_couchdb(model_class, db_name, batch_size = DEFAULT_BULK_BATCH_SIZE, &record_filter)
      # Use the provided filter or default to non-retired records
      query = record_filter ? record_filter.call(model_class) : default_filter(model_class)
      
      # Optimize query by selecting only needed columns
      query = optimize_query_select(query, model_class)

      total_count = query.count
      model_name = model_class.name.downcase
      last_updated = source_last_updated(model_class, query)
      SyncProgress.start(db_name, total_count)

      # Check record counts and clean CouchDB if needed. When already in sync we
      # still want a (completed) progress row so every table shows on the dashboard.
      if check_and_clean_couchdb_if_needed_for_model(model_class, db_name, query, last_updated) == :skip_sync
        SyncProgress.finish(db_name)
        return
      end

      Sidekiq.logger.info "Starting #{use_bulk_sync? ? 'BULK' : 'STANDARD'} sync of #{total_count} #{model_name.pluralize} to CouchDB"

      if use_bulk_sync?
        sync_records_bulk(query, db_name, batch_size, total_count, model_name)
      else
        sync_records_individual(query, db_name, batch_size, total_count, model_name)
      end

      # Record the synced signature so an unchanged table is skipped next run.
      write_couch_sync_meta(db_name, total_count, last_updated)
    end
    
    # Bulk sync implementation for model-based records
    def sync_records_bulk(query, db_name, batch_size, total_count, model_name)
      ensure_database_exists(db_name)

      processed = 0
      errors = []
      batch_number = 0

      query.find_in_batches(batch_size: batch_size) do |batch|
        batch_number += 1

        success = sync_batch_with_retry(batch, db_name, model_name, batch_number, errors, max_retries: 5)

        if success
          processed += batch.size
          SyncProgress.set(db_name, processed)
          Sidekiq.logger.info "Synced #{processed}/#{total_count} #{model_name.pluralize}"
        else
          # Batch ultimately failed after all retries - log and continue
          Sidekiq.logger.error "Batch #{batch_number} failed permanently, skipping #{batch.size} records"
          batch.size.times { errors << "Batch #{batch_number} failed permanently" }
        end

        sleep(0.5) # Give CouchDB breathing room between batches
      end

      handle_sync_completion(processed, errors, total_count, model_name, progress_key: db_name)
    end

    # Retry a single batch with exponential backoff and CouchDB recovery waiting
    def sync_batch_with_retry(batch, db_name, model_name, batch_number, errors, max_retries: 5)
      retries = 0

      begin
        documents = batch.map { |record| prepare_bulk_document(record) }
        bulk_result = bulk_sync_to_couchdb(documents, db_name)

        if bulk_result[:success]
          if bulk_result[:errors].any?
            errors.concat(bulk_result[:errors])
            Sidekiq.logger.warn "Batch #{batch_number} had #{bulk_result[:errors].length} document-level errors"
          end
          return true
        else
          raise "Bulk sync returned failure: #{bulk_result[:errors].join(', ')}"
        end

      rescue Errno::ECONNREFUSED, SocketError, RestClient::ServerBrokeConnection => e
        retries += 1

        if retries <= max_retries
          wait_time = [2 ** retries, 30].min # 2, 4, 8, 16, 30 seconds
          Sidekiq.logger.warn "Batch #{batch_number} connection error (attempt #{retries}/#{max_retries}): #{e.message}. Waiting #{wait_time}s for CouchDB to recover..."

          sleep(wait_time)

          # Verify CouchDB is back up before retrying
          if wait_for_couchdb(timeout: wait_time * 2)
            Sidekiq.logger.info "CouchDB recovered, retrying batch #{batch_number}..."
            retry
          else
            Sidekiq.logger.error "CouchDB did not recover in time, skipping batch #{batch_number}"
            errors << "Batch #{batch_number} failed: CouchDB unavailable after #{max_retries} retries"
            return false
          end
        else
          Sidekiq.logger.error "Batch #{batch_number} failed after #{max_retries} retries: #{e.message}"
          errors << "Batch #{batch_number} permanently failed: #{e.message}"
          return false
        end

      rescue => e
        retries += 1
        if retries <= max_retries
          sleep(1 * retries)
          retry
        else
          Sidekiq.logger.error "Batch #{batch_number} failed after #{max_retries} retries: #{e.message}"
          errors << "Batch #{batch_number} failed: #{e.message}"
          return false
        end
      end
    end

    # Poll CouchDB until it responds or timeout is reached
    def wait_for_couchdb(timeout: 60)  # increase from 30 to 60
      deadline = Time.now + timeout
      interval = 3  # poll every 3 seconds

      while Time.now < deadline
        begin
          RestClient.get(couchdb_url('_up'))
          Sidekiq.logger.info "CouchDB is back up!"
          return true
        rescue Errno::ECONNREFUSED, SocketError
          Sidekiq.logger.info "Waiting for CouchDB to come back up..."
          sleep(interval)
        rescue => e
          return true # any HTTP response means it's running
        end
      end

      false
    end
    # Original individual sync (kept for backwards compatibility and fallback)
    def sync_records_individual(query, db_name, batch_size, total_count, model_name)
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
            consecutive_errors = 0
            
            add_rate_limiting_delay(index)
            log_progress(processed, total_count, model_name.pluralize, skipped)
            
          rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
            consecutive_errors = handle_connection_error(record, e, consecutive_errors, errors)
            
          rescue => e
            handle_general_error(record, e, errors)
          end
        end
        
        sleep(0.1)
        SyncProgress.set(db_name, processed)
        Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} #{model_name.pluralize} so far. Skipped: #{skipped}"
      end

      handle_sync_completion(processed, errors, total_count, model_name, skipped, progress_key: db_name)
    end
    
    # Enhanced sync method for custom queries with bulk support
    def sync_custom_query_to_couchdb(query, count_query, db_name, data_type_name, batch_size = DEFAULT_BULK_BATCH_SIZE, progress_interval: 25, rate_limit_interval: 10)
      total_count = count_query.count
      SyncProgress.start(db_name, total_count)

      if check_and_clean_couchdb_if_needed_for_custom(count_query, db_name, data_type_name) == :skip_sync
        SyncProgress.finish(db_name)
        return
      end

      Sidekiq.logger.info "Starting #{use_bulk_sync? ? 'BULK' : 'STANDARD'} sync of #{total_count} #{data_type_name.pluralize}"
      
      if use_bulk_sync?
        sync_custom_bulk(query, db_name, batch_size, total_count, data_type_name)
      else
        sync_custom_individual(query, db_name, batch_size, total_count, data_type_name, progress_interval, rate_limit_interval)
      end
    end
    
    # Bulk sync for custom queries
    def sync_custom_bulk(query, db_name, batch_size, total_count, data_type_name)
      ensure_database_exists(db_name)
  
      processed = 0
      errors = []
      
      cursor_options = { batch_size: batch_size }
      cursor_options[:cursor] = get_batch_cursor if respond_to?(:get_batch_cursor, true) && get_batch_cursor

      query.find_in_batches(**cursor_options) do |batch|
        begin
          documents = batch.map { |record| prepare_bulk_document(record) }
          bulk_result = bulk_sync_to_couchdb(documents, db_name)

          processed += batch.size
          SyncProgress.set(db_name, processed)
          errors.concat(bulk_result[:errors]) if bulk_result[:errors].any?

          Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"

        rescue => e
          Sidekiq.logger.error "Batch failed: #{e.message}"
          errors << e.message
          
          # Fallback to individual sync
          batch.each do |record|
            begin
              sync_record_to_couchdb(record, db_name)
            rescue => individual_error
              errors << individual_error.message
            end
          end
        end
        
        sleep(0.05)
      end
      
      handle_sync_completion(processed, errors, total_count, data_type_name, progress_key: db_name)
    end
    
    # Original custom query individual sync
    def sync_custom_individual(query, db_name, batch_size, total_count, data_type_name, progress_interval, rate_limit_interval)
      processed = 0
      errors = []
      consecutive_errors = 0
      
      query.find_in_batches(batch_size: batch_size) do |batch|
        batch.each_with_index do |record, index|
          begin
            sync_record_to_couchdb(record, db_name)
            processed += 1
            consecutive_errors = 0
            
            if (index + 1) % rate_limit_interval == 0
              sleep(0.01)
            end
            
            if processed % progress_interval == 0
              Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"
            end
            
          rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
            consecutive_errors = handle_connection_error(record, e, consecutive_errors, errors)
            
          rescue => e
            handle_general_error(record, e, errors)
          end
        end
        
        sleep(0.1)
        SyncProgress.set(db_name, processed)
        Sidekiq.logger.info "Completed batch. Processed #{processed}/#{total_count} #{data_type_name.pluralize} so far."
      end

      handle_sync_completion(processed, errors, total_count, data_type_name, progress_key: db_name)
    end

    # Enhanced sync method for array-based data with bulk support
    def sync_array_to_couchdb(data_array, db_name, data_type_name, batch_size = DEFAULT_BULK_BATCH_SIZE, progress_interval: 25, rate_limit_interval: 5)
      total_count = data_array.length
      SyncProgress.start(db_name, total_count)

      if check_and_clean_couchdb_if_needed_for_array(data_array, db_name, data_type_name) == :skip_sync
        SyncProgress.finish(db_name)
        return
      end

      Sidekiq.logger.info "Starting #{use_bulk_sync? ? 'BULK' : 'STANDARD'} sync of #{total_count} #{data_type_name.pluralize}"
      
      if use_bulk_sync?
        sync_array_bulk(data_array, db_name, batch_size, total_count, data_type_name)
      else
        sync_array_individual(data_array, db_name, batch_size, total_count, data_type_name, progress_interval, rate_limit_interval)
      end
    end
    
    # Bulk sync for arrays
    def sync_array_bulk(data_array, db_name, batch_size, total_count, data_type_name)
      ensure_database_exists(db_name)
      
      processed = 0
      errors = []
      
      data_array.each_slice(batch_size).with_index do |batch, batch_index|
        begin
          documents = batch.map { |record| prepare_bulk_document(record) }
          bulk_result = bulk_sync_to_couchdb(documents, db_name)

          processed += batch.size
          SyncProgress.set(db_name, processed)
          errors.concat(bulk_result[:errors]) if bulk_result[:errors].any?

          Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"

        rescue => e
          Sidekiq.logger.error "Batch #{batch_index} failed: #{e.message}"
          errors << e.message
          
          # Fallback to individual sync
          batch.each do |record|
            begin
              sync_record_to_couchdb(record, db_name)
            rescue => individual_error
              errors << individual_error.message
            end
          end
        end
        
        sleep(0.05)
      end
      
      handle_sync_completion(processed, errors, total_count, data_type_name, progress_key: db_name)
    end
    
    # Original array individual sync
    def sync_array_individual(data_array, db_name, batch_size, total_count, data_type_name, progress_interval, rate_limit_interval)
      processed = 0
      errors = []
      consecutive_errors = 0
      
      data_array.each_slice(batch_size).with_index do |batch, batch_index|
        batch.each_with_index do |record, index|
          begin
            sync_record_to_couchdb(record, db_name)
            processed += 1
            consecutive_errors = 0
            
            if (index + 1) % rate_limit_interval == 0
              sleep(0.01)
            end
            
            if processed % progress_interval == 0
              Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"
            end
            
          rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
            consecutive_errors = handle_connection_error(record, e, consecutive_errors, errors)
            
          rescue => e
            handle_general_error(record, e, errors)
          end
        end
        
        sleep(0.1)
        SyncProgress.set(db_name, processed)
        Sidekiq.logger.info "Completed batch #{batch_index + 1}. Processed #{processed}/#{total_count} #{data_type_name.pluralize} so far."
      end

      handle_sync_completion(processed, errors, total_count, data_type_name, progress_key: db_name)
    end
    
    # NEW: Bulk sync to CouchDB using _bulk_docs endpoint
    def bulk_sync_to_couchdb(documents, db_name, manage_indexes: true)
      db_url = couchdb_url(db_name)
      bulk_url = "#{db_url}/_bulk_docs"

      # Defensive dedupe: joins can produce duplicate rows that map to the same _id.
      unique_documents = documents.reverse.uniq { |doc| doc['_id'] }.reverse
      duplicate_count = documents.length - unique_documents.length
      if duplicate_count.positive?
        Sidekiq.logger.warn "Bulk sync de-duplicated #{duplicate_count} duplicate documents for #{db_name}"
      end

      unique_documents = normalize_search_documents(unique_documents, db_name)
      if manage_indexes
        PatientRecordSearchFields.ensure_couchdb_indexes!(db_url, logger: Sidekiq.logger) if db_name.to_s == PatientRecordSearchFields::PATIENT_RECORD_DB
        ReferenceDataSearchFields.ensure_couchdb_indexes!(db_url, db_name, logger: Sidekiq.logger)
      end

      # Fetch existing _revs to avoid conflicts
      existing_revs = fetch_existing_revs(unique_documents, db_url)

      # Merge _rev into documents that already exist
      documents_with_revs = unique_documents.map do |doc|
        rev = existing_revs[doc['_id']]
        rev ? doc.merge('_rev' => rev) : doc
      end

      bulk_data = { 'docs' => documents_with_revs }

      retries = 0
      begin
        response = RestClient.post(
          bulk_url,
          bulk_data.to_json,
          { content_type: :json, accept: :json }
        )
        result = JSON.parse(response.body)
        errors = result.select { |r| r.key?('error') }.map do |err|
          "Doc #{err['id']}: #{err['error']} - #{err['reason']}"
        end
        { success: true, errors: errors }
      rescue RestClient::Exception, SocketError => e
        retries += 1
        retries <= 2 ? (sleep(0.1 * retries); retry) : { success: false, errors: ["Bulk sync failed: #{e.message}"] }
      end
    end

    def normalize_search_documents(documents, db_name)
      documents.map do |doc|
        normalized_doc = doc.deep_dup
        PatientRecordSearchFields.normalize_if_patient_record!(normalized_doc, db_name)
        ReferenceDataSearchFields.normalize_if_supported!(normalized_doc, db_name)
        normalized_doc
      end
    end

    def fetch_existing_revs(documents, db_url)
      ids = documents.map { |d| d['_id'] }
      response = RestClient.post(
        "#{db_url}/_all_docs",
        { keys: ids }.to_json,
        { content_type: :json, accept: :json }
      )
      result = JSON.parse(response.body)
      result['rows'].each_with_object({}) do |row, hash|
        hash[row['id']] = row['value']['rev'] if row['value'] && !row['value']['deleted']
      end
    rescue => e
      Sidekiq.logger.warn "Could not fetch existing revs: #{e.message}"
      {}
    end
    
    # NEW: Prepare document with _id for bulk operations
    def prepare_bulk_document(record)
      record_for_doc = record.is_a?(Hash) ? record.with_indifferent_access : record
      doc = prepare_document(record_for_doc)
      doc_id = generate_document_id(record_for_doc)
      doc.merge("_id" => doc_id)
    end
    
    # Transient CouchDB connection errors worth retrying. CouchDB closing the
    # socket mid-request surfaces as RestClient::ServerBrokeConnection (wrapping
    # an EOFError), which is exactly what happens when the server is restarting
    # or saturated. A 404 is NOT transient and must propagate.
    COUCHDB_TRANSIENT_ERRORS = [
      RestClient::ServerBrokeConnection,
      RestClient::Exceptions::OpenTimeout,
      RestClient::Exceptions::ReadTimeout,
      RestClient::RequestTimeout,
      RestClient::BadGateway,
      RestClient::ServiceUnavailable,
      RestClient::GatewayTimeout,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EPIPE,
      SocketError,
      EOFError
    ].freeze

    def with_couchdb_retries(max_attempts: 5, base_delay: 0.5)
      attempt = 0
      begin
        yield
      rescue *COUCHDB_TRANSIENT_ERRORS => e
        attempt += 1
        raise if attempt >= max_attempts

        delay = base_delay * (2**(attempt - 1))
        Sidekiq.logger.warn("CouchDB transient error (attempt #{attempt}/#{max_attempts}): #{e.class}: #{e.message}; retrying in #{delay}s")
        sleep(delay)
        retry
      end
    end

    # NEW: Ensure database exists
    def ensure_database_exists(db_name, manage_indexes: true)
      db_url = couchdb_url(db_name)
      created = false
      begin
        with_couchdb_retries { RestClient.get(db_url) }
      rescue RestClient::NotFound
        with_couchdb_retries { RestClient.put(db_url, {}.to_json, { content_type: :json }) }
        Sidekiq.logger.info "Created CouchDB database: #{db_name}"
        created = true
      end

      return unless manage_indexes

      PatientRecordSearchFields.ensure_couchdb_indexes!(db_url, logger: Sidekiq.logger, force: created) if db_name.to_s == PatientRecordSearchFields::PATIENT_RECORD_DB
      ReferenceDataSearchFields.ensure_couchdb_indexes!(db_url, db_name, logger: Sidekiq.logger, force: created)
    end
    
    # NEW: Optimize query by selecting only needed columns
    def optimize_query_select(query, model_class)
      # Get columns needed for document preparation
      # Subclasses can override get_required_columns to specify which columns they need
      if respond_to?(:get_required_columns, true)
        required_columns = get_required_columns
        query.select(*required_columns) if required_columns.present?
      end
      query
    end
    
    # NEW: Check if bulk sync should be used
    def use_bulk_sync?
      # Can be overridden in subclasses to disable bulk sync
      defined?(self.class::BULK_SYNC_ENABLED) ? self.class::BULK_SYNC_ENABLED : BULK_SYNC_ENABLED
    end
    
    # All other existing methods remain unchanged...
    # (check_and_clean_couchdb_if_needed_for_model, get_couchdb_record_count, etc.)
    
    # CouchDB _local doc storing the last-synced signature for a database. _local
    # docs are lightweight, don't replicate, and aren't counted in doc_count.
    SYNC_META_DOC = '_local/sync_meta'

    # Latest source-side update timestamp for the records being synced, derived
    # from the standard OpenMRS audit columns. Returns nil when the table has no
    # timestamp columns (reference data) — callers then fall back to count-only.
    def source_last_updated(model_class, query)
      ts_cols = %w[date_changed date_created] & model_class.column_names
      return nil if ts_cols.empty?

      ts_cols.filter_map { |col| query.maximum(col) }.max
    end

    def normalize_ts(timestamp)
      return nil if timestamp.nil?

      timestamp.respond_to?(:utc) ? timestamp.utc.iso8601 : timestamp.to_s
    end

    def couch_sync_meta(db_name)
      response = with_couchdb_retries { RestClient.get(couchdb_url(db_name, SYNC_META_DOC)) }
      JSON.parse(response.body)
    rescue RestClient::NotFound
      nil
    rescue StandardError => e
      Sidekiq.logger.warn "Could not read sync meta for #{db_name}: #{e.message}"
      nil
    end

    def write_couch_sync_meta(db_name, count, last_updated)
      existing = couch_sync_meta(db_name)
      body = { 'count' => count.to_i, 'last_updated' => normalize_ts(last_updated) }
      body['_rev'] = existing['_rev'] if existing && existing['_rev']
      with_couchdb_retries { RestClient.put(couchdb_url(db_name, SYNC_META_DOC), body.to_json, { content_type: :json }) }
    rescue StandardError => e
      Sidekiq.logger.warn "Could not write sync meta for #{db_name}: #{e.message}"
    end

    # True when CouchDB already holds exactly this data: same record count and,
    # when a source timestamp is available, the same last-updated high-water mark.
    def already_synced?(db_name, mysql_count, couchdb_count, last_updated)
      return false unless mysql_count == couchdb_count
      return true if last_updated.nil? # no timestamp column → count match is enough

      meta = couch_sync_meta(db_name)
      return false unless meta

      meta['count'].to_i == mysql_count && meta['last_updated'].to_s == normalize_ts(last_updated)
    end

    def check_and_clean_couchdb_if_needed_for_model(model_class, db_name, query, last_updated = nil)
      begin
        mysql_count = query.count
        couchdb_count = get_couchdb_dataset_count(db_name)
        model_name = model_class.name.downcase

        Sidekiq.logger.info "MySQL #{model_name} count: #{mysql_count}, CouchDB #{model_name} count: #{couchdb_count}"

        if already_synced?(db_name, mysql_count, couchdb_count, last_updated)
          Sidekiq.logger.info "#{model_name}: already in sync (count + last update match). Skipping."
          return :skip_sync
        end

        if mysql_count != couchdb_count
          Sidekiq.logger.warn "Record count mismatch detected! MySQL: #{mysql_count}, CouchDB: #{couchdb_count}"
          Sidekiq.logger.info "Cleaning all #{model_name} records from CouchDB before sync..."

          delete_all_records_from_couchdb(db_name, get_document_prefix(model_class), model_name)

          Sidekiq.logger.info "Successfully cleaned all #{model_name} records from CouchDB"
          return :continue_sync
        else
          # Count matches but the source changed since last sync: upsert in place
          # (no delete needed since the id set is unchanged).
          Sidekiq.logger.info "#{model_name}: count matches but source changed since last sync; re-syncing in place."
          return :continue_sync
        end

      rescue => e
        model_name = model_class.name.downcase
        Sidekiq.logger.error "Error checking CouchDB record count: #{e.message}"
        Sidekiq.logger.info "Proceeding with sync despite count check failure..."
        return :continue_sync
      end
    end
    
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
    
    # Count of real (non-design) documents in a database. Each sync database
    # holds a single document type, so this equals the dataset size regardless
    # of how document ids are formed (UUIDs, prefixed keys, etc.) — unlike the
    # prefix scan, which silently returns 0 when ids aren't prefixed.
    def get_couchdb_dataset_count(db_name)
      db_url = couchdb_url(db_name)
      info = JSON.parse(with_couchdb_retries { RestClient.get(db_url) }.body)
      info['doc_count'].to_i - couchdb_design_doc_count(db_name)
    rescue RestClient::NotFound
      Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
      0
    rescue StandardError => e
      Sidekiq.logger.error "Error getting CouchDB dataset count for #{db_name}: #{e.message}"
      raise e
    end

    def couchdb_design_doc_count(db_name)
      response = with_couchdb_retries { RestClient.get("#{couchdb_url(db_name)}/_design_docs") }
      JSON.parse(response.body)['rows'].length
    rescue StandardError
      0
    end

    def get_couchdb_record_count(db_name, document_prefix)
      begin
        db_url = couchdb_url(db_name)
        response = RestClient.get(db_url)
        db_info = JSON.parse(response.body)
        
        require 'uri'
        start_key = URI.encode_www_form_component("\"#{document_prefix}\"")
        end_key = URI.encode_www_form_component("\"#{document_prefix}\\ufff0\"")
        
        view_url = "#{db_url}/_all_docs?startkey=#{start_key}&endkey=#{end_key}"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        return result['rows']&.length || 0
        
      rescue RestClient::NotFound
        Sidekiq.logger.info "CouchDB database '#{db_name}' not found. Will be created during sync."
        return 0
      rescue => e
        Sidekiq.logger.error "Error getting CouchDB record count: #{e.message}"
        raise e
      end
    end
    
    def get_couchdb_type_count(db_name, document_type)
      begin
        db_url = couchdb_url(db_name)
        response = RestClient.get(db_url)
        db_info = JSON.parse(response.body)
        
        view_url = "#{db_url}/_all_docs"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        type_count = 0
        result['rows'].each do |row|
          next if row['id'].start_with?('_design')
          
          begin
            doc_response = RestClient.get("#{db_url}/#{row['id']}")
            doc = JSON.parse(doc_response.body)
            type_count += 1 if doc['type'] == document_type
          rescue => e
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
    
    def delete_all_records_by_type_from_couchdb(db_name, document_type, model_name)
      begin
        db_url = couchdb_url(db_name)
        
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
          return
        end
        
        view_url = "#{db_url}/_all_docs?include_docs=true"
        response = RestClient.get(view_url)
        result = JSON.parse(response.body)
        
        type_docs = result['rows'].select do |row|
          !row['id'].start_with?('_design') && row['doc'] && row['doc']['type'] == document_type
        end
        
        if type_docs.empty?
          Sidekiq.logger.info "No #{model_name} documents found in CouchDB. Nothing to clean."
          return
        end
        
        Sidekiq.logger.info "Found #{type_docs.length} #{model_name} documents to delete"
        
        docs_to_delete = type_docs.map do |row|
          {
            "_id" => row['id'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        perform_bulk_delete(db_url, docs_to_delete, model_name)
        
      rescue => e
        Sidekiq.logger.error "Error deleting #{model_name.pluralize} from CouchDB: #{e.message}"
        raise e
      end
    end
    
    def delete_all_records_from_couchdb(db_name, document_prefix, model_name)
      begin
        db_url = couchdb_url(db_name)
        
        begin
          RestClient.get(db_url)
        rescue RestClient::NotFound
          Sidekiq.logger.info "Database '#{db_name}' doesn't exist. Nothing to clean."
          return
        end
        
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
        
        docs_to_delete = result['rows'].map do |row|
          {
            "_id" => row['id'],
            "_rev" => row['doc']['_rev'],
            "_deleted" => true
          }
        end
        
        perform_bulk_delete(db_url, docs_to_delete, model_name)
        
      rescue => e
        Sidekiq.logger.error "Error deleting #{model_name.pluralize} from CouchDB: #{e.message}"
        raise e
      end
    end
    
    def sync_record_to_couchdb(record, db_name)
      record_for_doc = record.is_a?(Hash) ? record.with_indifferent_access : record
      doc_data = prepare_document(record_for_doc)
      doc_id = generate_document_id(record_for_doc)

      retries = 0
      begin
        sync_to_couchdb(doc_data, db_name, doc_id)
      rescue RestClient::Exception, SocketError => e
        retries += 1
        if retries <= 2
          sleep(0.1 * retries)
          retry
        else
          raise e
        end
      end
    end
    
    private
    
    def default_filter(model_class)
      if model_class.column_names.include?('retired')
        model_class.where(retired: [0, false])
      else
        model_class.all
      end
    end
    
    def get_document_prefix(model_class)
      "#{model_class.name.downcase}_"
    end
    
    def add_rate_limiting_delay(index)
      if (index + 1) % 10 == 0
        sleep(0.01)
      end
    end
    
    def log_progress(processed, total_count, model_name, skipped = 0)
      if processed % 100 == 0
        if skipped > 0
          Sidekiq.logger.info "Synced #{processed}/#{total_count} #{model_name} (skipped: #{skipped})"
        else
          Sidekiq.logger.info "Synced #{processed}/#{total_count} #{model_name}"
        end
      end
    end
    
    def handle_connection_error(record, error, consecutive_errors, errors)
      consecutive_errors += 1
      record_id = get_record_identifier(record)
      error_msg = "Failed to sync #{record.class.name.downcase} ID #{record_id}: #{error.message}"
      Sidekiq.logger.error error_msg
      errors << error_msg
      
      sleep_time = [0.1 * (2 ** [consecutive_errors - 1, 5].min), 5.0].min
      sleep(sleep_time)
      
      if consecutive_errors >= 5
        raise "Too many consecutive connection errors (#{consecutive_errors}). Stopping sync. Last error: #{error.message}"
      end
      
      consecutive_errors
    end
    
    def handle_general_error(record, error, errors)
      record_id = get_record_identifier(record)
      record_type = record.respond_to?(:class) ? record.class.name.downcase : 'record'
      error_msg = "Failed to sync #{record_type} ID #{record_id}: #{error.message}"
      Sidekiq.logger.error error_msg
      errors << error_msg
      sleep(0.05)
    end
    
    def handle_sync_completion(processed, errors, total_count, model_name, skipped = 0, progress_key: nil)
      # processed already counts only successful batches, errors are logged separately
      success_count = processed
      key = progress_key || model_name
      SyncProgress.set(key, processed)

      if skipped > 0
        Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors, #{skipped} skipped"
      else
        Sidekiq.logger.info "Sync completed: #{success_count} successful, #{errors.length} errors"
      end

      if errors.any?
        Sidekiq.logger.error "Total errors: #{errors.length}"
        Sidekiq.logger.error "Show all errors: #{errors}"
        if errors.length > total_count * 0.05
          error_rate = (errors.length.to_f / total_count * 100).round(2)
          SyncProgress.fail(key, "error rate #{error_rate}% (#{errors.length}/#{total_count})")
          raise "#{model_name.capitalize} sync completed with unacceptable error rate: #{errors.length}/#{total_count} (#{error_rate}%)"
        end
      end

      SyncProgress.finish(key)
    end
    
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
      
      errors = delete_result.select { |result| result.key?('error') }
      if errors.any?
        Sidekiq.logger.error "Failed to delete #{errors.length} documents:"
        errors.each { |error| Sidekiq.logger.error "  #{error}" }
      end
    end
    
    def get_record_identifier(record)
      %w[drug_id village_id id].each do |field|
        return record.send(field) if record.respond_to?(field)
      end
      record.id
    end
    
    def prepare_document(record)
      raise NotImplementedError, "Subclasses must implement prepare_document method"
    end
    
    def generate_document_id(record)
      raise NotImplementedError, "Subclasses must implement generate_document_id method"
    end
  end
end
