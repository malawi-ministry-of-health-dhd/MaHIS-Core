# frozen_string_literal: true

# Background job to rebuild patient lab data in response to lab events
# This job is triggered by ActiveSupport::Notifications from the his_emr_api_lab gem
class RebuildPatientLabDataJob < ApplicationJob
  include CouchdbSync

  PATIENTS_DB = 'patients_records'
  COUCHDB_UPDATE_ATTEMPTS = 3

  queue_as :patient_records

  # Retry with exponential backoff on failures
  retry_on StandardError, wait: :exponentially_longer, attempts: 5

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
      update_couchdb_lab_orders(document_id, lab_orders_data)
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
    patient = Patient.includes(:patient_identifiers).find_by(patient_id: patient_id)
    raise "Patient not found for labOrders rebuild: #{patient_id}" unless patient

    identifiers_by_type = BuildPatientRecordService.patient_identifiers_by_type(patient)
    document_id = BuildPatientRecordService.patient_identifier_from_map(identifiers_by_type, 3, patient_id)
    raise "Patient record ID missing for labOrders rebuild: #{patient_id}" if document_id.blank?

    document_id
  end

  def update_couchdb_lab_orders(document_id, lab_orders_data)
    ensure_db_exists(PATIENTS_DB)

    doc_url = couchdb_url(PATIENTS_DB, URI.encode_www_form_component(document_id.to_s))
    attempt = 1

    begin
      document = JSON.parse(RestClient.get(doc_url).body)
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
    raise "Patient CouchDB document #{document_id} not found; cannot update labOrders only"
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
