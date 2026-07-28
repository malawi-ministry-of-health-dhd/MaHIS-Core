# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'set'

# Closes the gap between MySQL patients and CouchDB patient documents after a
# bulk sync fan-out. The fan-out (Sync::BatchPatientSyncJob -> many
# Sync::BulkPatientRecordSyncJob) can leave permanent holes:
#   * batches that exhausted their Sidekiq retries land in the dead set and are
#     never retried, so their patients never reach CouchDB;
#   * two patients that share the same primary identifier (identifier_type 3)
#     map to the same CouchDB `_id` and overwrite each other, so the achievable
#     document count is the number of DISTINCT primary identifiers, not the
#     number of patients.
#
# This service performs one reconciliation pass: it walks every eligible patient
# in keyset batches, asks CouchDB which `_id`s already exist, and re-enqueues the
# ones that are missing. It also emits a report that explains the count gap
# (collisions + patients without a primary identifier) so "CouchDB count <
# Patient count" can be understood rather than chased forever.
#
# It never changes the document `_id` scheme (the offline client looks patients
# up by their primary identifier), so duplicate-identifier collisions are
# reported, not silently "fixed".
class PatientSyncReconciler
  PRIMARY_IDENTIFIER_TYPE = 3
  DEFAULT_DB_NAME = 'patients_records'
  PERMANENT_FAILURES_KEY = 'sync:patients:permanent_failures'
  FAILURE_TTL_SECONDS = 24 * 60 * 60

  SCAN_BATCH = 2_000        # identifier rows pulled from MySQL per page
  COUCH_KEYS_BATCH = 1_000  # ids per CouchDB _all_docs presence check
  ENQUEUE_SLICE = 50        # patients per re-enqueued BulkPatientRecordSyncJob
  PUSH_BULK_SIZE = 200      # job arg-tuples per Sidekiq push_bulk

  Result = Struct.new(
    :total_patients, :eligible, :distinct_ids, :collisions, :no_identifier,
    :couch_count, :present, :missing, :missing_reenqueued,
    :permanent_failures, :errored,
    keyword_init: true
  )

  def self.reconcile!(logger: Rails.logger, db_name: DEFAULT_DB_NAME, enqueue_missing: true)
    new(logger: logger, db_name: db_name).reconcile!(enqueue_missing: enqueue_missing)
  end

  # Eligibility scope shared by the bulk producer and reconciliation pass. A
  # patient can only produce a CouchDB document when a non-voided, nonblank
  # type-3 identifier supplies the document ID.
  def self.eligible_identifier_scope
    PatientIdentifier
      .where(identifier_type: PRIMARY_IDENTIFIER_TYPE, voided: 0)
      .where.not(identifier: [nil, ''])
      .joins('INNER JOIN patient ON patient.patient_id = patient_identifier.patient_id AND patient.voided = 0')
  end

  # BuildPatientRecordService chooses one document ID per patient: the newest
  # non-voided type-3 identifier. Mirror that rule in SQL so progress and
  # reconciliation do not treat a patient's older identifiers as additional
  # documents that can never be created. patient_identifier_id breaks
  # date_created ties deterministically and is mirrored by
  # PatientIdentifierService.
  def self.canonical_identifier_scope
    eligible_identifier_scope.where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1
        FROM patient_identifier newer
        WHERE newer.patient_id = patient_identifier.patient_id
          AND newer.identifier_type = #{PRIMARY_IDENTIFIER_TYPE}
          AND newer.voided = 0
          AND newer.identifier IS NOT NULL
          AND newer.identifier <> ''
          AND (
            COALESCE(newer.date_created, '1970-01-01 00:00:00') >
              COALESCE(patient_identifier.date_created, '1970-01-01 00:00:00')
            OR (
              COALESCE(newer.date_created, '1970-01-01 00:00:00') =
                COALESCE(patient_identifier.date_created, '1970-01-01 00:00:00')
              AND newer.patient_identifier_id > patient_identifier.patient_identifier_id
            )
          )
      )
    SQL
  end

  def self.eligible_patient_ids
    canonical_identifier_scope.select('patient_identifier.patient_id')
  end

  # Duplicate canonical identifiers across patients map to the same CouchDB
  # `_id`, so their distinct count is the maximum achievable document count.
  def self.distinct_primary_identifier_count
    canonical_identifier_scope.distinct.count('patient_identifier.identifier')
  end

  def self.record_permanent_failure(patient_id, reason)
    Sidekiq.redis do |redis|
      redis.hset(PERMANENT_FAILURES_KEY, patient_id.to_i.to_s, reason.to_s)
      redis.expire(PERMANENT_FAILURES_KEY, FAILURE_TTL_SECONDS)
    end
  rescue StandardError => e
    Rails.logger.warn("Could not record permanent patient sync failure #{patient_id}: #{e.message}")
  end

  def self.permanent_failures
    Sidekiq.redis { |redis| redis.hgetall(PERMANENT_FAILURES_KEY) }
  rescue StandardError
    {}
  end

  def self.clear_run_failures!
    Sidekiq.redis { |redis| redis.del(PERMANENT_FAILURES_KEY) }
  rescue StandardError => e
    Rails.logger.warn("Could not clear permanent patient sync failures: #{e.message}")
  end

  def initialize(logger: Rails.logger, db_name: DEFAULT_DB_NAME)
    @logger = logger
    @db_name = db_name
  end

  def reconcile!(enqueue_missing: true)
    unless CouchdbPatientService.couchdb_configured?
      @logger.warn('PatientSyncReconciler: CouchDB not configured; skipping reconciliation')
      return Result.new(missing: 0, missing_reenqueued: 0, permanent_failures: 0, errored: false)
    end

    report = build_report
    log_report(report)

    missing, present, reenqueued, permanent_failures = reenqueue_missing(enqueue: enqueue_missing)
    report.present = present
    report.missing = missing
    report.missing_reenqueued = enqueue_missing ? reenqueued : 0
    report.permanent_failures = permanent_failures

    SyncProgress.ensure(@db_name, report.distinct_ids)
    SyncProgress.set(@db_name, present)

    if enqueue_missing
      @logger.info("PatientSyncReconciler: re-enqueued #{reenqueued} of #{missing} missing patient(s) this pass")
    else
      @logger.info("PatientSyncReconciler: final audit found #{missing} missing patient document(s)")
    end
    report
  rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
    @logger.warn("PatientSyncReconciler: CouchDB error during reconciliation: #{e.class}: #{e.message}")
    Result.new(missing: 0, missing_reenqueued: 0, permanent_failures: 0, errored: true)
  rescue StandardError => e
    @logger.error("PatientSyncReconciler: unexpected error: #{e.class}: #{e.message}")
    Result.new(missing: 0, missing_reenqueued: 0, permanent_failures: 0, errored: true)
  end

  private

  def build_report
    total_patients = Patient.count
    eligible = canonical_identifier_scope.count
    distinct_ids = canonical_identifier_scope.distinct.count('patient_identifier.identifier')
    couch_count = CouchdbPatientService.patient_record_count(@db_name)

    Result.new(
      total_patients: total_patients,
      eligible: eligible,
      distinct_ids: distinct_ids,
      collisions: eligible - distinct_ids,
      no_identifier: total_patients - eligible,
      couch_count: couch_count,
      present: 0,
      missing: 0,
      missing_reenqueued: 0,
      permanent_failures: 0,
      errored: false
    )
  end

  def log_report(report)
    @logger.info(
      'PatientSyncReconciler report: ' \
      "MySQL patients=#{report.total_patients}; " \
      "with primary identifier=#{report.eligible}; " \
      "without primary identifier (never synced)=#{report.no_identifier}; " \
      "distinct primary identifiers=#{report.distinct_ids}; " \
      "duplicate-identifier collisions (overwrite each other, unsyncable)=#{report.collisions}; " \
      "achievable CouchDB docs=~#{report.distinct_ids}; " \
      "current CouchDB docs=#{report.couch_count.nil? ? 'unknown' : report.couch_count}"
    )

    if report.collisions.positive? || report.no_identifier.positive?
      @logger.warn(
        'PatientSyncReconciler: CouchDB can never equal Patient.count with the ' \
        "current `_id` scheme: #{report.no_identifier} patient(s) have no primary " \
        "identifier and #{report.collisions} patient(s) share a primary identifier " \
        'with another patient. Clean these in MySQL to close the gap.'
      )
    end
  end

  # Re-enqueue every eligible patient whose canonical CouchDB document is
  # missing. Keyset over patient_identifier_id so every canonical identifier row
  # is visited exactly once.
  def reenqueue_missing(enqueue: true)
    last_row_id = 0
    missing_total = 0
    reenqueued_total = 0
    present_total = 0
    permanent_total = 0
    bulk_args = []
    pending = []
    seen_identifiers = Set.new
    permanent_failure_ids = self.class.permanent_failures.keys.map(&:to_i).to_set

    loop do
      rows = canonical_identifier_scope
             .where('patient_identifier.patient_identifier_id > ?', last_row_id)
             .order('patient_identifier.patient_identifier_id')
             .limit(SCAN_BATCH)
             .pluck('patient_identifier.patient_identifier_id', 'patient_identifier.patient_id', 'patient_identifier.identifier')
      break if rows.empty?

      last_row_id = rows.last.first
      rows = rows.reject do |row|
        already_seen = seen_identifiers.include?(row[2])
        seen_identifiers << row[2]
        already_seen
      end

      present = couch_present_ids(rows.map { |row| row[2] }.uniq)
      present_total += present.size
      missing_patient_ids = rows.reject { |row| present.include?(row[2]) }
                                .map { |row| row[1] }
                                .uniq

      missing_patient_ids.each do |patient_id|
        missing_total += 1
        if permanent_failure_ids.include?(patient_id)
          permanent_total += 1
          next
        end

        pending << patient_id
        next if pending.size < ENQUEUE_SLICE

        bulk_args << [pending, { 'location_id' => nil }]
        reenqueued_total += pending.size
        pending = []
        flush(bulk_args) if enqueue && bulk_args.size >= PUSH_BULK_SIZE
      end
    end

    if pending.any?
      bulk_args << [pending, { 'location_id' => nil }]
      reenqueued_total += pending.size
    end
    flush(bulk_args) if enqueue && bulk_args.any?

    [missing_total, present_total, reenqueued_total, permanent_total]
  end

  def flush(bulk_args)
    Sync::BulkPatientRecordSyncJob.perform_bulk(bulk_args)
    bulk_args.clear
  end

  # Ask CouchDB which of these document ids exist (POST _all_docs with keys).
  # Missing keys come back as {"key" => k, "error" => "not_found"}.
  def couch_present_ids(ids)
    present = Set.new
    ids.each_slice(COUCH_KEYS_BATCH) do |chunk|
      response = RestClient.post(
        CouchdbPatientService.couchdb_url(@db_name, '_all_docs'),
        { keys: chunk }.to_json,
        { content_type: :json, accept: :json }
      )
      JSON.parse(response.body)['rows'].each do |row|
        next if row['error']

        value = row['value']
        present << row['key'] if value && !value['deleted']
      end
    end
    present
  end

  # Non-voided primary identifiers that belong to a non-voided patient. The
  # patient join mirrors the bulk job, which only builds non-voided patients
  # (Patient's default scope) — without it a voided patient that still has a live
  # identifier would be re-enqueued every round and never reach a clean pass.
  def eligible_identifier_scope
    self.class.eligible_identifier_scope
  end

  def canonical_identifier_scope
    self.class.canonical_identifier_scope
  end
end
