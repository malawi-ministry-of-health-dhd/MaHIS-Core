# frozen_string_literal: true

# Rebuilds the full ART summary (art_summary, minus visit history) from MySQL and
# trues up the patients_records CouchDB doc. Runs off-request after any save that
# could affect ART data, so the Mastercard's registration/staging/enrollment
# fields (art_start_date, hiv_test_date, reason_for_art_eligibility, etc.) are
# always backed by the authoritative source instead of whatever partial
# rootLevelContext snapshot the client happened to compute at save time.
class RebuildArtSummaryJob < ApplicationJob
  include CouchdbSync

  PATIENTS_DB = 'patients_records'

  queue_as :patient_records

  retry_on StandardError, wait: :exponentially_longer, attempts: 5

  def perform(patient_id, trigger:, metadata: {})
    return unless couchdb_configured?

    Rails.logger.info("RebuildArtSummaryJob: Starting rebuild for patient #{patient_id} - Trigger: #{trigger}")
    Rails.logger.debug("RebuildArtSummaryJob: Metadata: #{metadata.inspect}")
    start_time = Time.current

    patient = Patient.unscoped.includes(:person).find_by(patient_id: patient_id)
    unless patient
      Rails.logger.warn("RebuildArtSummaryJob: Patient #{patient_id} not found; skipping")
      return
    end

    document_id = PatientRecordIdentityService.document_id(patient: patient)
    unless document_id.present?
      Rails.logger.warn("RebuildArtSummaryJob: No CouchDB document id for patient #{patient_id}; skipping")
      return
    end

    document = fetch_couchdb_doc(PATIENTS_DB, document_id)
    unless document
      Rails.logger.warn("RebuildArtSummaryJob: CouchDB document #{document_id} not found; skipping")
      return
    end

    existing_art_summary = document['art_summary']
    return unless existing_art_summary.is_a?(Hash)

    fresh_art_summary = ArtService::PatientSummaryBuilder.new(patient_id).build.as_json

    # Merge each date's rebuilt fields over the existing visit rather than
    # keeping the old visit wholesale: the builder is authoritative for every
    # field it derives (weight, outcome, tb_status, pills_dispensed, etc.), so
    # a stale/incorrect value there must be overwritten. Any extra keys the
    # client stored that the builder doesn't derive (e.g. free-text notes)
    # survive since the client's hash is the merge base.
    existing_visits = existing_art_summary['visits']
    if existing_visits.is_a?(Hash)
      fresh_art_summary['visits'] = existing_visits.merge(fresh_art_summary['visits']) do |_date, old_visit, new_visit|
        old_visit.is_a?(Hash) && new_visit.is_a?(Hash) ? old_visit.merge(new_visit) : new_visit
      end
    end

    if existing_art_summary == fresh_art_summary
      Rails.logger.debug("RebuildArtSummaryJob: art_summary for #{document_id} unchanged; skipping CouchDB write")
      return
    end

    document['art_summary'] = fresh_art_summary
    sync_to_couchdb(document, PATIENTS_DB, document_id)

    duration = (Time.current - start_time).round(3)
    Rails.logger.info("RebuildArtSummaryJob: Updated art_summary in CouchDB for patient #{patient_id} in #{duration}s")
  rescue StandardError => e
    Rails.logger.error("RebuildArtSummaryJob: Failed for patient #{patient_id}: #{e.message}")
    Rails.logger.error("RebuildArtSummaryJob: Backtrace - #{e.backtrace.first(10).join("\n")}")
    raise
  end
end
