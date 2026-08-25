# frozen_string_literal: true

# Background job to rebuild patient lab data in response to lab events
# This job is triggered by ActiveSupport::Notifications from the his_emr_api_lab gem
class RebuildPatientLabDataJob < ApplicationJob
  include CouchdbSync

  PATIENTS_DB = 'patients_records'
  COUCHDB_UPDATE_ATTEMPTS = 3

  queue_as :patient_records

  # Retry with exponential backoff on failures (2^x seconds: 1s, 4s, 9s, 16s, 25s)

  sidekiq_options retry: 5

  def perform(patient_id, trigger:, metadata: {})
    Rails.logger.info("RebuildPatientLabDataJob: Starting rebuild for patient #{patient_id} - Trigger: #{trigger}")
    Rails.logger.debug("RebuildPatientLabDataJob: Metadata: #{metadata.inspect}")

    start_time = Time.current

    begin
      lab_orders_data = BuildPatientRecordService.build_lab_orders_data(patient_id).as_json
      Rails.logger.debug("RebuildPatientLabDataJob: Lab orders rebuilt - #{Array(lab_orders_data['saved']).count} orders")

      unless couchdb_configured?
        Rails.logger.warn("RebuildPatientLabDataJob: CouchDB not configured; skipping labOrders update for patient #{patient_id}")
        return
      end

      document_id = patient_document_id(patient_id)
      update_couchdb_lab_orders(document_id, lab_orders_data, patient_id)
      Rails.logger.info("RebuildPatientLabDataJob: Updated labOrders in CouchDB for patient #{patient_id}")

      duration = (Time.current - start_time).round(3)
      Rails.logger.info("RebuildPatientLabDataJob: Successfully completed for patient #{patient_id} in #{duration}s")

      # Optional: Track rebuild event for analytics/auditing
      track_rebuild_event(patient_id, trigger, metadata, duration)

    rescue StandardError => e
      Rails.logger.error("RebuildPatientLabDataJob: Failed for patient #{patient_id}: #{e.message}")
      Rails.logger.error("RebuildPatientLabDataJob: Backtrace - #{e.backtrace.first(10).join("\n")}")

      # Re-raise to trigger retry mechanism
      raise
    end
  end

  private

  def patient_document_id(patient_id)
    patient = Patient.includes(:person).find_by(patient_id: patient_id)
    raise "Patient not found for labOrders rebuild: #{patient_id}" unless patient
    raise "Person not found for patient #{patient_id}" unless patient.person

    document_id = patient.person.uuid
    raise "Person UUID missing for patient #{patient_id}" if document_id.blank?

    document_id
  end

  def update_couchdb_lab_orders(document_id, lab_orders_data, patient_id)
    ensure_db_exists(PATIENTS_DB)

    doc_url = couchdb_url(PATIENTS_DB, URI.encode_www_form_component(document_id.to_s))
    attempt = 1

    begin
      document = JSON.parse(RestClient.get(doc_url).body)

      # Most saves don't change historical lab orders, so the rebuilt list usually
      # equals what's already in CouchDB. Skip the write when unchanged: a no-op
      # PUT still advances the doc revision and can collide with a replicating
      # client, needlessly widening the conflict window.
      if document['labOrders'] == lab_orders_data
        Rails.logger.debug("RebuildPatientLabDataJob: labOrders for #{document_id} unchanged; skipping CouchDB write")
        return
      end

      document['labOrders'] = lab_orders_data

      RestClient.put(
        doc_url,
        document.to_json,
        { content_type: :json, accept: :json }
      )
    rescue RestClient::Conflict, RestClient::PreconditionFailed
      raise if attempt >= COUCHDB_UPDATE_ATTEMPTS

      attempt += 1
      Rails.logger.warn(
        "RebuildPatientLabDataJob: CouchDB conflict updating #{document_id}; " \
        "retrying attempt #{attempt}/#{COUCHDB_UPDATE_ATTEMPTS}"
      )
      sleep(0.1 * attempt)
      retry
    end
  rescue RestClient::NotFound
    rebuild_couchdb_patient_document(patient_id, document_id)
  end

  def rebuild_couchdb_patient_document(patient_id, document_id)
    Rails.logger.warn(
      "RebuildPatientLabDataJob: Patient CouchDB document #{document_id} not found; " \
      "rebuilding full patient document for patient #{patient_id}"
    )

    patient_record = BuildPatientRecordService.build_patient_record(patient_id)
    raise "Unable to rebuild full patient CouchDB document for patient #{patient_id}" if patient_record.blank?

    rebuilt_document_id = PatientRecordIdentityService.document_id(record: patient_record)
    if rebuilt_document_id.to_s != document_id.to_s
      raise "Rebuilt patient #{patient_id} generated CouchDB document #{rebuilt_document_id}; expected #{document_id}"
    end

    sync_to_couchdb(patient_record.as_json, PATIENTS_DB, document_id)
  end

  def track_rebuild_event(patient_id, trigger, _metadata, duration)
    # Optional: Store rebuild events for analytics or auditing
    # This could write to a separate audit table or analytics system
    Rails.logger.info(
      "RebuildPatientLabDataJob: Event tracked - " \
      "Patient: #{patient_id}, Trigger: #{trigger}, Duration: #{duration}s"
    )
  rescue StandardError => e
    # Don't fail the job if event tracking fails
    Rails.logger.warn("RebuildPatientLabDataJob: Failed to track event: #{e.message}")
  end
end
