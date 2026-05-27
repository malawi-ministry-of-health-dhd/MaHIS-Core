# app/jobs/sync/ensure_patient_indexes_job.rb
require 'sidekiq/api'

module Sync
  # Builds the patient search indexes once, after the bulk patient sync fan-out
  # has drained. The bulk jobs deliberately skip index creation so CouchDB is
  # not re-indexing on every write; this job creates the indexes a single time
  # over the fully loaded dataset. It polls and reschedules itself while bulk
  # jobs are still queued or running, so it works without Sidekiq Pro batches.
  class EnsurePatientIndexesJob
    include Sidekiq::Job
    include CouchdbSync

    sidekiq_options queue: :batch_sync, retry: 5

    PATIENT_SYNC_QUEUE = 'patient_sync'
    POLL_INTERVAL = 30
    REQUIRED_EMPTY_POLLS = 2      # consecutive idle reads before we commit
    MAX_ATTEMPTS = 480           # ~4h safety cap so we never poll forever

    def perform(attempt = 0, consecutive_idle = 0)
      consecutive_idle = patient_sync_idle? ? consecutive_idle + 1 : 0

      if consecutive_idle >= REQUIRED_EMPTY_POLLS || attempt >= MAX_ATTEMPTS
        build_patient_indexes
        return
      end

      self.class.perform_in(POLL_INTERVAL, attempt + 1, consecutive_idle)
    end

    private

    def patient_sync_idle?
      return false if Sidekiq::Queue.new(PATIENT_SYNC_QUEUE).size.positive?
      return false if scheduled_or_retrying_patient_sync?

      no_patient_sync_in_progress?
    rescue StandardError => e
      Sidekiq.logger.warn("EnsurePatientIndexesJob idle check failed: #{e.class}: #{e.message}")
      false
    end

    def scheduled_or_retrying_patient_sync?
      [Sidekiq::RetrySet.new, Sidekiq::ScheduledSet.new].any? do |set|
        set.any? { |job| job.queue == PATIENT_SYNC_QUEUE }
      end
    end

    def no_patient_sync_in_progress?
      Sidekiq::Workers.new.none? do |_process, _thread, work|
        queue_for(work) == PATIENT_SYNC_QUEUE
      end
    end

    def queue_for(work)
      return work.queue if work.respond_to?(:queue)

      payload = work.is_a?(Hash) ? (work['payload'] || work) : work
      payload = JSON.parse(payload) if payload.is_a?(String)
      payload['queue']
    rescue StandardError
      nil
    end

    def build_patient_indexes
      unless couchdb_configured?
        Sidekiq.logger.warn('EnsurePatientIndexesJob: CouchDB not configured, skipping index build')
        return
      end

      db_url = couchdb_url(PatientRecordSearchFields::PATIENT_RECORD_DB)
      PatientRecordSearchFields.ensure_couchdb_indexes!(db_url, logger: Sidekiq.logger, force: true)
      SyncProgress.finish('patients_records')
      Sidekiq.logger.info('EnsurePatientIndexesJob: patient search indexes ensured after bulk sync completion')
    end
  end
end
