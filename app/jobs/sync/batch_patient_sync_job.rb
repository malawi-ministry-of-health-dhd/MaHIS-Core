# app/jobs/sync/batch_patient_sync_job.rb
module Sync
  class BatchPatientSyncJob
    include Sidekiq::Job
    sidekiq_options queue: :batch_sync, retry: 3

    DEFAULT_BATCH_SIZE = 50
    PATIENT_FETCH_MULTIPLIER = 20
    SIDEKIQ_BULK_PUSH_SIZE = 200

    # When CouchDB holds fewer than this fraction of the MySQL patient count, a
    # default sync runs a FULL sweep instead of an incremental one, so a prior
    # partial run gets backfilled by the parallel fan-out (the reconciliation
    # pass also catches stragglers, but a full sweep parallelises the bulk work).
    FULL_SYNC_COMPLETENESS_THRESHOLD = 0.9

    # Rolling window used by the live, per-encounter sync triggered from the
    # controller. Wide enough to re-sync recently-active patients at the location
    # while keeping each enqueued job's encounter scan bounded.
    RECENT_SYNC_LOOKBACK = 24.hours

    # Lower-bound `since_date` for the live patient sync enqueued on every
    # encounter save. Deliberately cheap (no CouchDB round trip) because it runs
    # inside the web request, and returned as an ISO8601 string so it survives
    # Sidekiq's strict JSON argument serialization (raw Time objects are rejected)
    # and parses cleanly via parse_since_date's Time.zone.parse.
    def self.recent_since_date
      RECENT_SYNC_LOOKBACK.ago.iso8601
    end

    def perform(location_id = nil, since_date = nil, batch_size = 50)
      if location_id.present?
        Rails.logger.info("Starting batch patient sync for location #{location_id}")
      else
        Rails.logger.info("Starting batch patient sync for ALL locations")
      end

      since_date = default_since_date(location_id) if since_date.blank?
      parsed_since_date = parse_since_date(since_date)
      normalized_batch_size = normalize_batch_size(batch_size)

      # Reconciliation (re-enqueue missing patients) only runs for the full /
      # all-locations sync. Per-location and per-encounter triggers skip it so a
      # single encounter save never kicks off a full-database reconciliation.
      reconcile = location_id.blank?

      # Anchor the progress row to the true totals (all patients vs. how many are
      # already in CouchDB) before fanning out, so it reflects the whole patient
      # population rather than just this run's delta — an incremental run that
      # re-syncs one changed patient should still read "N/N", not "1/1". The live
      # count is refreshed from CouchDB by EnsurePatientIndexesJob as it drains.
      initialize_patient_progress if reconcile

      total_patients, total_jobs = sync_patients_in_bulk(location_id, parsed_since_date, normalized_batch_size)

      if total_patients.zero?
        Rails.logger.info('No patient records queued; scheduling patient search index verification')
        EnsurePatientIndexesJob.perform_async('reconcile' => reconcile)
        return
      end

      location_msg = location_id.present? ? "for location #{location_id}" : "for ALL locations"
      Rails.logger.info("Queued #{total_jobs} bulk sync jobs for #{total_patients} patients #{location_msg} (#{normalized_batch_size} patients per job)")

      # Bulk jobs skip index creation; build the patient search indexes once the
      # fan-out has drained so CouchDB indexes a single time over the full dataset.
      # For a full sync this also reconciles missing patients before finishing.
      EnsurePatientIndexesJob.perform_async('reconcile' => reconcile)
    end

    private

    # Seed the patient progress row from ground truth: total = all patients,
    # done = how many are already in CouchDB. EnsurePatientIndexesJob keeps `done`
    # current from CouchDB as the fan-out drains, so the row never reads as the
    # per-run delta (e.g. "1/1") when most patients are already synced.
    def initialize_patient_progress
      total = Patient.count
      synced = CouchdbPatientService.patient_record_count.to_i
      SyncProgress.start('patients_records', total)
      SyncProgress.set('patients_records', [synced, total].min) if total.positive?
    rescue StandardError => e
      Rails.logger.warn("Could not initialise patient sync progress: #{e.class}: #{e.message}")
    end

    def normalize_batch_size(batch_size)
      size = batch_size.to_i
      return DEFAULT_BATCH_SIZE if size <= 0

      size
    end

    def parse_since_date(since_date)
      return nil if since_date.blank?

      Time.zone.parse(since_date.to_s)
    rescue ArgumentError, TypeError
      Rails.logger.warn("Invalid since_date '#{since_date}', defaulting to full sync")
      nil
    end

    def default_since_date(location_id)
      return CouchdbPatientService.get_latest_encounter_date_changed if location_id.present?

      mysql_count = Patient.count
      couchdb_count = CouchdbPatientService.patient_record_count

      if couchdb_count.nil?
        Rails.logger.warn('Could not compare MySQL and CouchDB patient counts; falling back to incremental patient sync')
        return CouchdbPatientService.get_latest_encounter_date_changed
      end

      # CouchDB is materially behind (e.g. a previous run died part-way): a `nil`
      # since_date forces the full patient-table sweep so the whole backlog is
      # re-enqueued in parallel instead of relying on incremental encounter dates,
      # which would skip patients whose encounters have not changed.
      if couchdb_count < (mysql_count * FULL_SYNC_COMPLETENESS_THRESHOLD)
        Rails.logger.warn("CouchDB holds #{couchdb_count}/#{mysql_count} patient records " \
                          "(< #{(FULL_SYNC_COMPLETENESS_THRESHOLD * 100).to_i}%); forcing a full patient sync to backfill")
        return nil
      end

      CouchdbPatientService.get_latest_encounter_date_changed
    end

    def patient_sync_scope(location_id, parsed_since_date)
      scope = Encounter.unscoped.where.not(patient_id: nil)

      # encounter.location_id is a string in this schema
      scope = scope.where(location_id: location_id.to_s) if location_id.present?

      if parsed_since_date.present?
        scope = scope.where('encounter.date_created >= ?', parsed_since_date)
      end

      scope
    end

    def sync_patients_in_bulk(location_id, parsed_since_date, batch_size)
      if full_initial_sync?(location_id, parsed_since_date)
        Rails.logger.info('Using patient table for initial full sync')
        enqueue_patient_batches(location_id, batch_size) do |last_patient_id, patient_fetch_size|
          next_patient_batch(last_patient_id, patient_fetch_size)
        end
      else
        patient_scope = patient_sync_scope(location_id, parsed_since_date)
        enqueue_patient_batches(location_id, batch_size) do |last_patient_id, patient_fetch_size|
          next_encounter_patient_batch(patient_scope, last_patient_id, patient_fetch_size)
        end
      end
    end

    def full_initial_sync?(location_id, parsed_since_date)
      location_id.blank? && parsed_since_date.blank?
    end

    def enqueue_patient_batches(location_id, batch_size)
      patient_fetch_size = [batch_size * PATIENT_FETCH_MULTIPLIER, batch_size].max
      last_patient_id = -1
      total_patients = 0
      total_jobs = 0
      bulk_args = []

      loop do
        patient_ids = yield(last_patient_id, patient_fetch_size)
        break if patient_ids.empty?

        last_patient_id = patient_ids.last

        patient_ids.each_slice(batch_size) do |batch_ids|
          bulk_args << [batch_ids, { 'location_id' => location_id }]
          total_patients += batch_ids.size

          next unless bulk_args.size >= SIDEKIQ_BULK_PUSH_SIZE

          total_jobs += push_bulk_jobs(bulk_args)
          bulk_args = []
        end

        Rails.logger.info("Queued bulk sync for #{total_patients} patients so far") if (total_patients % 5_000).zero?
      end

      total_jobs += push_bulk_jobs(bulk_args) if bulk_args.any?
      [total_patients, total_jobs]
    end

    def next_encounter_patient_batch(patient_scope, last_patient_id, patient_fetch_size)
      patient_scope.where('encounter.patient_id > ?', last_patient_id)
                   .reorder(nil)
                   .select(:patient_id)
                   .distinct
                   .order(patient_id: :asc)
                   .limit(patient_fetch_size)
                   .pluck(:patient_id)
    end

    def next_patient_batch(last_patient_id, patient_fetch_size)
      Patient.where('patient.patient_id > ?', last_patient_id)
             .reorder(nil)
             .order(patient_id: :asc)
             .limit(patient_fetch_size)
             .pluck(:patient_id)
    end

    def push_bulk_jobs(bulk_args)
      job_ids = BulkPatientRecordSyncJob.perform_bulk(bulk_args)
      return bulk_args.size unless job_ids.is_a?(Array)

      job_ids.size
    end
  end
end

# Usage examples:
# Sync::BatchPatientSyncJob.perform_async                          # All locations, 50 patients per batch
# Sync::BatchPatientSyncJob.perform_async(700)                     # Specific location
# Sync::BatchPatientSyncJob.perform_async(nil, '2000-01-01')      # With date filter
# Sync::BatchPatientSyncJob.perform_async(nil, nil, 25)           # Smaller batches (25 patients)
# Sync::BatchPatientSyncJob.perform_async(nil, nil, 100)          # Larger batches (100 patients)
