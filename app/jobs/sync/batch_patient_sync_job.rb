# app/jobs/sync/batch_patient_sync_job.rb
module Sync
  class BatchPatientSyncJob
    include Sidekiq::Job
    sidekiq_options queue: :batch_sync, retry: 3

    DEFAULT_BATCH_SIZE = 50
    PATIENT_FETCH_MULTIPLIER = 20
    SIDEKIQ_BULK_PUSH_SIZE = 200

    def perform(location_id = nil, since_date = nil, batch_size = 50)
      if location_id.present?
        Rails.logger.info("Starting batch patient sync for location #{location_id}")
      else
        Rails.logger.info("Starting batch patient sync for ALL locations")
      end

      since_date ||= CouchdbPatientService.get_latest_encounter_date_changed
      parsed_since_date = parse_since_date(since_date)
      normalized_batch_size = normalize_batch_size(batch_size)

      total_patients, total_jobs = sync_patients_in_bulk(location_id, parsed_since_date, normalized_batch_size)

      return if total_patients.zero?

      location_msg = location_id.present? ? "for location #{location_id}" : "for ALL locations"
      Rails.logger.info("Queued #{total_jobs} bulk sync jobs for #{total_patients} patients #{location_msg} (#{normalized_batch_size} patients per job)")

      # Bulk jobs skip index creation; build the patient search indexes once the
      # fan-out has drained so CouchDB indexes a single time over the full dataset.
      EnsurePatientIndexesJob.perform_async
    end

    private

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
      Patient.unscoped.where('patient.patient_id > ?', last_patient_id)
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
