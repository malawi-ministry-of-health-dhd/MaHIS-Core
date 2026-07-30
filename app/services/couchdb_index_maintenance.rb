# frozen_string_literal: true

class CouchdbIndexMaintenance
  include CouchdbSync

  def self.ensure_reference_data!(logger: Rails.logger)
    new(logger:).ensure_reference_data!
  end

  def self.ensure_patient_records!(logger: Rails.logger)
    new(logger:).ensure_patient_records!
  end

  def self.ensure_all!(logger: Rails.logger)
    maintenance = new(logger:)
    reference_data_ok = maintenance.ensure_reference_data!
    patient_records_ok = maintenance.ensure_patient_records!
    reference_data_ok && patient_records_ok
  end

  def self.prune_patient_records!(logger: Rails.logger)
    new(logger:).prune_patient_records!
  end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def ensure_reference_data!
    return false unless couchdb_configured?

    results = ReferenceDataSearchFields::COUCHDB_INDEXES.keys.map do |db_name|
      ensure_database(db_name) &&
        ReferenceDataSearchFields.ensure_couchdb_indexes!(couchdb_url(db_name), db_name, logger: @logger, force: true)
    end

    results.all?
  end

  def ensure_patient_records!
    return false unless couchdb_configured?

    db_name = PatientRecordSearchFields::PATIENT_RECORD_DB
    ensure_database(db_name) &&
      PatientRecordSearchFields.ensure_couchdb_indexes!(couchdb_url(db_name), logger: @logger, force: true)
  end

  # Deliberately NOT wired into the sync path — deleting design docs is an
  # explicit maintenance action, not something a bulk sync batch should do.
  #
  # Ensures the current (grouped) indexes exist and are verified BEFORE deleting
  # the design docs they replace. Pruning first would leave patients_records with
  # no usable index for the duration of the rebuild, turning every patient search
  # into a full scan. If the ensure step cannot confirm every index, nothing is
  # deleted and this returns false.
  def prune_patient_records!
    return false unless couchdb_configured?

    unless ensure_patient_records!
      @logger&.warn('CouchDB patient search: skipping prune — current indexes could not be verified')
      return false
    end

    db_name = PatientRecordSearchFields::PATIENT_RECORD_DB
    db_url = couchdb_url(db_name)

    # Whole design docs from the pre-consolidation layout...
    CouchdbIndexEnsurer.prune!(
      db_url,
      PatientRecordSearchFields::RETIRED_COUCHDB_INDEXES,
      logger: @logger,
      label: 'CouchDB patient search'
    )
    # ...then individual indexes left inside the groups we own, e.g. the old
    # idx_patient_identifier now superseded by the client-named idx_ID within the
    # same design doc. Runs after ensure!, so the replacement already exists.
    CouchdbIndexEnsurer.prune_unknown_indexes!(
      db_url,
      PatientRecordSearchFields::COUCHDB_INDEXES,
      logger: @logger,
      label: 'CouchDB patient search'
    )
    true
  end

  private

  def ensure_database(db_name)
    db_url = couchdb_url(db_name)
    RestClient.get(db_url)
    true
  rescue RestClient::NotFound
    RestClient.put(db_url, {}.to_json, { content_type: :json, accept: :json })
    @logger&.info("Created CouchDB database: #{db_name}")
    true
  rescue StandardError => e
    @logger&.warn("Could not ensure CouchDB database #{db_name}: #{e.class}: #{e.message}")
    false
  end
end
