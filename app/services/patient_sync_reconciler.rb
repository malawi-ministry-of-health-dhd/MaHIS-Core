# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'set'

# Closes the gap between MySQL patients and CouchDB patient documents after a
# bulk sync fan-out. Patient documents are keyed by the permanent Person UUID,
# never by the mutable DDE NPID. Duplicate or temporarily missing NPIDs therefore
# do not make a patient ineligible and cannot make two patients overwrite one
# another in CouchDB.
class PatientSyncReconciler
  PRIMARY_IDENTIFIER_TYPE = 3
  DEFAULT_DB_NAME = 'patients_records'

  SCAN_BATCH = 2_000        # identifier rows pulled from MySQL per page
  COUCH_KEYS_BATCH = 1_000  # ids per CouchDB _all_docs presence check
  ENQUEUE_SLICE = 50        # patients per re-enqueued BulkPatientRecordSyncJob
  PUSH_BULK_SIZE = 200      # job arg-tuples per Sidekiq push_bulk

  Result = Struct.new(
    :total_patients, :eligible, :distinct_ids, :collisions, :no_identifier,
    :couch_count, :present, :missing, :missing_reenqueued, :errored,
    keyword_init: true
  )

  def self.reconcile!(logger: Rails.logger, db_name: DEFAULT_DB_NAME, enqueue_missing: true)
    new(logger: logger, db_name: db_name).reconcile!(enqueue_missing: enqueue_missing)
  end

  def self.eligible_patient_scope
    Patient.joins(:person).where.not(person: { uuid: [nil, ''] })
  end

  def self.eligible_patient_ids
    eligible_patient_scope.select('patient.patient_id')
  end

  def self.syncable_patient_count
    eligible_patient_scope.count
  end

  def initialize(logger: Rails.logger, db_name: DEFAULT_DB_NAME)
    @logger = logger
    @db_name = db_name
  end

  def reconcile!(enqueue_missing: true)
    unless CouchdbPatientService.couchdb_configured?
      @logger.warn('PatientSyncReconciler: CouchDB not configured; skipping reconciliation')
      return Result.new(missing: 0, missing_reenqueued: 0, errored: false)
    end

    report = build_report
    log_report(report)

    missing, present, reenqueued = reenqueue_missing(enqueue: enqueue_missing)
    report.present = present
    report.missing = missing
    report.missing_reenqueued = enqueue_missing ? reenqueued : 0

    SyncProgress.ensure(@db_name, report.eligible)
    SyncProgress.set(@db_name, present)

    if enqueue_missing
      @logger.info("PatientSyncReconciler: re-enqueued #{reenqueued} of #{missing} missing patient(s) this pass")
    else
      @logger.info("PatientSyncReconciler: final audit found #{missing} missing patient document(s)")
    end
    report
  rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
    @logger.warn("PatientSyncReconciler: CouchDB error during reconciliation: #{e.class}: #{e.message}")
    Result.new(missing: 0, missing_reenqueued: 0, errored: true)
  rescue StandardError => e
    @logger.error("PatientSyncReconciler: unexpected error: #{e.class}: #{e.message}")
    Result.new(missing: 0, missing_reenqueued: 0, errored: true)
  end

  private

  def build_report
    total_patients = Patient.count
    eligible = self.class.syncable_patient_count
    distinct_ids = distinct_primary_identifier_count
    couch_count = CouchdbPatientService.patient_record_count(@db_name)

    Result.new(
      total_patients: total_patients,
      eligible: eligible,
      distinct_ids: distinct_ids,
      collisions: duplicate_primary_identifier_owner_count,
      no_identifier: total_patients - eligible,
      couch_count: couch_count,
      present: 0,
      missing: 0,
      missing_reenqueued: 0,
      errored: false
    )
  end

  def log_report(report)
    @logger.info(
      'PatientSyncReconciler report: ' \
      "MySQL patients=#{report.total_patients}; " \
      "with permanent record UUID=#{report.eligible}; " \
      "without permanent record UUID (cannot sync)=#{report.no_identifier}; " \
      "distinct primary identifiers=#{report.distinct_ids}; " \
      "patients sharing a primary identifier=#{report.collisions}; " \
      "achievable CouchDB docs=#{report.eligible}; " \
      "current CouchDB docs=#{report.couch_count.nil? ? 'unknown' : report.couch_count}"
    )

    if report.no_identifier.positive?
      @logger.warn(
        "PatientSyncReconciler: #{report.no_identifier} patient(s) have no permanent Person UUID and cannot be synced."
      )
    end
    return unless report.collisions.positive?

    @logger.info(
      "PatientSyncReconciler: #{report.collisions} patient(s) share a DDE NPID; " \
      'their UUID-keyed documents remain independent and will request assignment when opened.'
    )
  end

  # Re-enqueue every UUID-addressable patient whose CouchDB document is missing.
  # Keyset over patient_id so every patient is visited exactly once.
  def reenqueue_missing(enqueue: true)
    last_patient_id = 0
    missing_total = 0
    reenqueued_total = 0
    present_total = 0
    bulk_args = []
    pending = []

    loop do
      rows = self.class.eligible_patient_scope
             .where('patient.patient_id > ?', last_patient_id)
             .order('patient.patient_id')
             .limit(SCAN_BATCH)
             .pluck('patient.patient_id', 'person.uuid')
      break if rows.empty?

      last_patient_id = rows.last.first
      document_ids = rows.map { |_patient_id, uuid| uuid.to_s }
      present = couch_present_ids(document_ids)
      present_total += present.size
      missing_patient_ids = rows.reject do |_patient_id, uuid|
        present.include?(uuid.to_s)
      end.map(&:first)

      missing_patient_ids.each do |patient_id|
        missing_total += 1
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

    [missing_total, present_total, reenqueued_total]
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

  def distinct_primary_identifier_count
    primary_identifier_scope.distinct.count(:identifier)
  end

  def duplicate_primary_identifier_owner_count
    grouped = primary_identifier_scope.group(:identifier).having('COUNT(DISTINCT patient_identifier.patient_id) > 1')
    grouped.count.values.sum { |count| count - 1 }
  end

  def primary_identifier_scope
    PatientIdentifier
      .where(identifier_type: PRIMARY_IDENTIFIER_TYPE, voided: 0)
      .where.not(identifier: [nil, ''])
      .joins('INNER JOIN patient ON patient.patient_id = patient_identifier.patient_id AND patient.voided = 0')
  end
end
