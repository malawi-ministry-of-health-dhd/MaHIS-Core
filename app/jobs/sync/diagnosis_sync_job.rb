# app/jobs/sync/diagnosis_sync_job.rb
module Sync
  class DiagnosisSyncJob < BaseSyncJob

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

    # Diagnoses use a deterministic "diagnosis_<concept_id>_<code>" id, so the
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
    # Uses keyset pagination on (concept_id, code) instead of OFFSET — on TiDB,
    # OFFSET is a distributed skip whose cost grows with the page number, which is
    # what made the diagnoses sync crawl on its final pages.
    def sync_custom_bulk(query, db_name, batch_size, total_count, data_type_name)
      ensure_database_exists(db_name)

      processed = 0
      errors = []
      last_concept_id = nil
      last_code = nil

      loop do
        batch = diagnoses_keyset_page(query, last_concept_id, last_code, batch_size)
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
        last_code = last.code
        sleep(0.05)
      end

      # progress_key: db_name ('diagnoses') — without it, finish() lands on the
      # data_type_name ('diagnosis') and the started 'diagnoses' bar never completes.
      handle_sync_completion(processed, errors, total_count, data_type_name, progress_key: db_name)
    end

    # One keyset page ordered by (concept_id, code). The document grain is
    # (concept_id, code) (id = "diagnosis_<concept_id>_<code>"), so this composite
    # cursor visits every distinct document; rows that share a (concept_id, code)
    # collapse to the same CouchDB doc, so skipping a boundary duplicate is safe.
    def diagnoses_keyset_page(query, last_concept_id, last_code, limit)
      scope = query.reorder(Arel.sql('concept_id ASC, code ASC'))

      if last_concept_id
        scope = scope.where(
          '(concept_name.concept_id > :cid) OR (concept_name.concept_id = :cid AND concept_map.concept_code > :code)',
          cid: last_concept_id, code: last_code
        )
      end

      scope.limit(limit).to_a
    end

    def get_diagnoses_query
      ConceptName
        .joins(concept_maps: :concept_source)
        .where(
          concept_source: { name: 'ICD-11' },
          locale_preferred: 1,
          voided: 0
        )
        .select(
          'concept_name.concept_id',
          'concept_name.name AS name',
          'concept_source.name AS code_system',
          'concept_map.concept_code AS code'
        )
        .distinct
        .order('concept_name.concept_id')
    end

    # Count must match the document grain: one doc per (concept_id, code), since
    # the document id is "diagnosis_<concept_id>_<code>". Counting distinct
    # concept_id alone undercounts and causes a permanent resync loop.
    def get_diagnoses_count_query
      ConceptName.unscoped.from(
        ConceptName
          .joins(concept_maps: :concept_source)
          .where(
            concept_source: { name: 'ICD-11' },
            locale_preferred: 1,
            voided: 0
          )
          .select('concept_name.concept_id, concept_map.concept_code AS code')
          .distinct,
        :concept_name
      )
    end

    def prepare_document(diagnosis)
      {
        "concept_id"  => diagnosis.concept_id,
        "name"        => diagnosis.name,
        "code"        => diagnosis.code,
      }
    end

    def generate_document_id(diagnosis)
      "diagnosis_#{diagnosis.concept_id}_#{diagnosis.code}"
    end
  end
end
