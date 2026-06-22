# app/jobs/sync/ensure_patient_indexes_job.rb
require 'sidekiq/api'

module Sync
  # Builds the patient search indexes once, after the bulk patient sync fan-out
  # has drained. The bulk jobs deliberately skip index creation so CouchDB is
  # not re-indexing on every write; this job creates the indexes a single time
  # over the fully loaded dataset. It polls and reschedules itself while bulk
  # jobs are still queued or running, so it works without Sidekiq Pro batches.
  #
  # When invoked with 'reconcile' => true (the full / all-locations sync), it
  # also runs a reconciliation pass once the queue drains: it re-enqueues any
  # patients missing from CouchDB and only builds the indexes after a pass finds
  # nothing missing (loop-until-dry). This is what guarantees "all of them" make
  # it to CouchDB even when individual bulk jobs failed and were never retried.
  class EnsurePatientIndexesJob
    include Sidekiq::Job
    include CouchdbSync

    sidekiq_options queue: :batch_sync, retry: 5

    PATIENT_SYNC_QUEUE = 'patient_sync'
    POLL_INTERVAL = 30
    REQUIRED_EMPTY_POLLS = 2      # consecutive idle reads before we commit
    MAX_ATTEMPTS = 480            # ~4h safety cap on a single drain-wait
    MAX_RECONCILE_ROUNDS = 5      # safety cap so a permanently-unbuildable patient can't loop forever

    def perform(state = {})
      state = {} unless state.is_a?(Hash)
      reconcile        = truthy(state['reconcile'])
      attempt          = state['attempt'].to_i
      consecutive_idle = state['consecutive_idle'].to_i
      reconcile_rounds = state['reconcile_rounds'].to_i

      consecutive_idle = patient_sync_idle? ? consecutive_idle + 1 : 0

      # Keep the dashboard's patient count honest while the fan-out drains: track
      # CouchDB's actual doc count rather than per-batch increments.
      refresh_patient_progress if reconcile

      unless consecutive_idle >= REQUIRED_EMPTY_POLLS || attempt >= MAX_ATTEMPTS
        return reschedule(reconcile, attempt + 1, consecutive_idle, reconcile_rounds)
      end

      forced = attempt >= MAX_ATTEMPTS

      if reconcile && !forced && reconcile_rounds < MAX_RECONCILE_ROUNDS
        return if run_reconciliation(reconcile_rounds)
      elsif reconcile && forced
        Sidekiq.logger.warn("EnsurePatientIndexesJob: drain wait hit the #{MAX_ATTEMPTS}-poll cap; building indexes without a final clean reconciliation pass")
      end

      build_patient_indexes
    end

    private

    # Runs one reconciliation pass. Returns true when the job has rescheduled
    # itself (and the caller should stop), false when it should fall through to
    # building the indexes (this pass found nothing missing).
    def run_reconciliation(reconcile_rounds)
      result = PatientSyncReconciler.reconcile!(logger: Sidekiq.logger)

      if result.errored
        Sidekiq.logger.warn('EnsurePatientIndexesJob: reconciliation hit a CouchDB error; will retry the drain/reconcile cycle')
        reschedule(true, 0, 0, reconcile_rounds)
        return true
      end

      if result.missing_reenqueued.positive?
        Sidekiq.logger.info("EnsurePatientIndexesJob: reconcile round #{reconcile_rounds + 1} re-enqueued #{result.missing_reenqueued} missing patient(s); waiting for the queue to drain again")
        reschedule(true, 0, 0, reconcile_rounds + 1)
        return true
      end

      Sidekiq.logger.info("EnsurePatientIndexesJob: reconcile round #{reconcile_rounds + 1} found no missing patients; finalizing")
      false
    end

    def reschedule(reconcile, attempt, consecutive_idle, reconcile_rounds)
      self.class.perform_in(
        POLL_INTERVAL,
        'reconcile' => reconcile,
        'attempt' => attempt,
        'consecutive_idle' => consecutive_idle,
        'reconcile_rounds' => reconcile_rounds
      )
    end

    def truthy(value)
      value == true || value.to_s == 'true' || value.to_s == '1'
    end

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

    # Update the patient progress row from CouchDB's actual doc count (ground
    # truth) so the dashboard shows synced/total for the whole population, not a
    # per-run delta. Total is re-asserted in case only an incremental run ran.
    def refresh_patient_progress
      total = Patient.count
      synced = CouchdbPatientService.patient_record_count.to_i
      SyncProgress.ensure('patients_records', total)
      SyncProgress.set('patients_records', [synced, total].min) if total.positive?
    rescue StandardError => e
      Sidekiq.logger.warn("EnsurePatientIndexesJob: could not refresh patient progress: #{e.class}: #{e.message}")
    end

    def build_patient_indexes
      unless couchdb_configured?
        Sidekiq.logger.warn('EnsurePatientIndexesJob: CouchDB not configured, skipping index build')
        return
      end

      CouchdbIndexMaintenance.ensure_patient_records!(logger: Sidekiq.logger)
      SyncProgress.finish('patients_records')
      Sidekiq.logger.info('EnsurePatientIndexesJob: patient search indexes verified after bulk sync completion')
    end
  end
end
