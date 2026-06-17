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

  SCAN_BATCH = 2_000        # identifier rows pulled from MySQL per page
  COUCH_KEYS_BATCH = 1_000  # ids per CouchDB _all_docs presence check
  ENQUEUE_SLICE = 50        # patients per re-enqueued BulkPatientRecordSyncJob
  PUSH_BULK_SIZE = 200      # job arg-tuples per Sidekiq push_bulk

  Result = Struct.new(
    :total_patients, :eligible, :distinct_ids, :collisions, :no_identifier,
    :couch_count, :present, :missing_reenqueued, :errored,
    keyword_init: true
  )

  def self.reconcile!(logger: Rails.logger, db_name: DEFAULT_DB_NAME)
    new(logger: logger, db_name: db_name).reconcile!
  end

  def initialize(logger: Rails.logger, db_name: DEFAULT_DB_NAME)
    @logger = logger
    @db_name = db_name
  end

  def reconcile!
    unless CouchdbPatientService.couchdb_configured?
      @logger.warn('PatientSyncReconciler: CouchDB not configured; skipping reconciliation')
      return Result.new(missing_reenqueued: 0, errored: false)
    end

    report = build_report
    log_report(report)

    missing = reenqueue_missing
    report.missing_reenqueued = missing
    @logger.info("PatientSyncReconciler: re-enqueued #{missing} missing patient(s) this pass")
    report
  rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
    @logger.warn("PatientSyncReconciler: CouchDB error during reconciliation: #{e.class}: #{e.message}")
    Result.new(missing_reenqueued: 0, errored: true)
  rescue StandardError => e
    @logger.error("PatientSyncReconciler: unexpected error: #{e.class}: #{e.message}")
    Result.new(missing_reenqueued: 0, errored: true)
  end

  private

  def build_report
    total_patients = Patient.count
    eligible = eligible_identifier_scope.distinct.count('patient_identifier.patient_id')
    distinct_ids = eligible_identifier_scope.distinct.count('patient_identifier.identifier')
    couch_count = CouchdbPatientService.patient_record_count(@db_name)

    Result.new(
      total_patients: total_patients,
      eligible: eligible,
      distinct_ids: distinct_ids,
      collisions: eligible - distinct_ids,
      no_identifier: total_patients - eligible,
      couch_count: couch_count,
      present: 0,
      missing_reenqueued: 0,
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

  # Re-enqueue every eligible patient whose CouchDB document is missing. Keyset
  # over patient_identifier_id so every identifier row is visited exactly once
  # (a patient may legitimately have more than one non-voided primary identifier).
  def reenqueue_missing
    last_row_id = 0
    missing_total = 0
    bulk_args = []
    pending = []

    loop do
      rows = eligible_identifier_scope
             .where('patient_identifier.patient_identifier_id > ?', last_row_id)
             .order('patient_identifier.patient_identifier_id')
             .limit(SCAN_BATCH)
             .pluck('patient_identifier.patient_identifier_id', 'patient_identifier.patient_id', 'patient_identifier.identifier')
      break if rows.empty?

      last_row_id = rows.last.first

      present = couch_present_ids(rows.map { |row| row[2] }.uniq)
      missing_patient_ids = rows.reject { |row| present.include?(row[2]) }
                                .map { |row| row[1] }
                                .uniq

      missing_patient_ids.each do |patient_id|
        pending << patient_id
        next if pending.size < ENQUEUE_SLICE

        bulk_args << [pending, { 'location_id' => nil }]
        missing_total += pending.size
        pending = []
        flush(bulk_args) if bulk_args.size >= PUSH_BULK_SIZE
      end
    end

    if pending.any?
      bulk_args << [pending, { 'location_id' => nil }]
      missing_total += pending.size
    end
    flush(bulk_args) if bulk_args.any?

    missing_total
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
    PatientIdentifier
      .where(identifier_type: PRIMARY_IDENTIFIER_TYPE, voided: 0)
      .where.not(identifier: [nil, ''])
      .joins('INNER JOIN patient ON patient.patient_id = patient_identifier.patient_id AND patient.voided = 0')
  end
end
