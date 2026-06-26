# app/jobs/sync/diagnosis_sync_job.rb
module Sync
  class DiagnosisSyncJob < BaseSyncJob
    DIAGNOSIS_CONCEPT_SET_NAME = 'ICD-10 Volume 3 Diagnosis'

    def perform(batch_size = 1000)
      sync_custom_query_to_couchdb(
        get_diagnoses_query,
        get_diagnoses_count_query,
        'diagnoses',
        'diagnosis',
        batch_size,
        progress_interval: 50,
        rate_limit_interval: 10
      )
    end

    private

    # Diagnoses use a deterministic "diagnosis_<concept_id>" id, so the
    # fast prefix-based count is accurate (the shared type-based count requires a
    # 'type' field these docs don't have, and reads every doc one-by-one).
    def check_and_clean_couchdb_if_needed_for_custom(count_query, db_name, data_type_name)
      source_count = count_query.count
      couchdb_count = get_couchdb_record_count(db_name, 'diagnosis_')
      Sidekiq.logger.info "Source #{data_type_name} count: #{source_count}, CouchDB #{data_type_name} count: #{couchdb_count}"

      if source_count == couchdb_count
        Sidekiq.logger.info 'Diagnoses already in sync. Skipping.'
        return :skip_sync
      end

      Sidekiq.logger.warn "Diagnoses count mismatch (source #{source_count}, CouchDB #{couchdb_count}); cleaning and re-syncing."
      delete_all_records_from_couchdb(db_name, 'diagnosis_', data_type_name)
      :continue_sync
    rescue StandardError => e
      Sidekiq.logger.error "Diagnoses count check failed: #{e.message}; proceeding with sync."
      :continue_sync
    end

    # Override to bypass find_in_batches (concept_name has no primary key).
    # Uses keyset pagination on concept_id instead of OFFSET — on TiDB,
    # OFFSET is a distributed skip whose cost grows with the page number, which is
    # what made the diagnoses sync crawl on its final pages.
    def sync_custom_bulk(query, db_name, batch_size, total_count, data_type_name)
      ensure_database_exists(db_name)

      processed = 0
      errors = []
      last_concept_id = nil

      loop do
        batch = diagnoses_keyset_page(query, last_concept_id, batch_size)
        break if batch.empty?

        begin
          documents = batch.map { |record| prepare_bulk_document(record) }
          # ensure_database_exists above already ensured the indexes once; skip the
          # per-batch index check and the per-batch _rev fetch (a fresh load after
          # the count-mismatch clean has no existing revs) to cut round trips ~half.
          bulk_result = bulk_sync_to_couchdb(documents, db_name, manage_indexes: false, prefetch_revs: false)

          processed += batch.size
          SyncProgress.set(db_name, processed)
          errors.concat(bulk_result[:errors]) if bulk_result[:errors].any?

          Sidekiq.logger.info "Synced #{processed}/#{total_count} #{data_type_name.pluralize}"
        rescue => e
          Sidekiq.logger.error "Batch failed: #{e.message}"
          errors << e.message

          batch.each do |record|
            begin
              sync_record_to_couchdb(record, db_name)
            rescue => individual_error
              errors << individual_error.message
            end
          end
        end

        last = batch.last
        last_concept_id = last.concept_id
        sleep(0.05)
      end

      # progress_key: db_name ('diagnoses') — without it, finish() lands on the
      # data_type_name ('diagnosis') and the started 'diagnoses' bar never completes.
      handle_sync_completion(processed, errors, total_count, data_type_name, progress_key: db_name)
    end

    def diagnoses_keyset_page(query, last_concept_id, limit)
      scope = query.reorder(Arel.sql('concept_name.concept_id ASC'))

      if last_concept_id
        scope = scope.where('concept_name.concept_id > ?', last_concept_id)
      end

      scope.limit(limit).to_a
    end

    def get_diagnoses_query
      concept_set_id = diagnosis_concept_set_id!

      ConceptName
        .joins('INNER JOIN concept_set s ON s.concept_id = concept_name.concept_id')
        .where('s.concept_set = ?', concept_set_id)
        .where(locale_preferred: 1, voided: 0)
        .select(
          'concept_name.concept_id',
          'concept_name.name AS name'
        )
        .distinct
        .order('concept_name.concept_id')
    end

    def get_diagnoses_count_query
      ConceptName.unscoped.from(get_diagnoses_query.except(:order), :concept_name)
    end

    def prepare_document(diagnosis)
      {
        "concept_id"  => diagnosis.concept_id,
        "name"        => diagnosis.name
      }
    end

    def generate_document_id(diagnosis)
      "diagnosis_#{diagnosis.concept_id}"
    end

    def diagnosis_concept_set_id!
      concept_id = ConceptName.where(name: DIAGNOSIS_CONCEPT_SET_NAME, voided: 0).pick(:concept_id)
      return concept_id if concept_id.present?

      raise "Missing concept set '#{DIAGNOSIS_CONCEPT_SET_NAME}'. Run `rails icd10_volume3:import_diagnoses` first."
    end
  end
end
