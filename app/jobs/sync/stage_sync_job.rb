# app/jobs/sync/stage_sync_job.rb
module Sync
  class StageSyncJob < BaseSyncJob

    def perform(batch_size = 50)
      query = Stage.includes(patient: :patient_identifiers)
                   .joins(:visit)
                   .joins('INNER JOIN patient ON patient.patient_id = visit.patient_id')
                   .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = visit.patient_id AND patient_identifier.identifier_type = 3')

      sync_custom_query_to_couchdb(
        query,
        query,
        'stages',
        'stage',
        batch_size,
        progress_interval: 10,
        rate_limit_interval: 5
      )
    end

    private

    def prepare_document(stage)
      patient = stage.visit&.patient
      unless patient
        Sidekiq.logger.warn "Skipping stage ID #{stage.id}: no patient via visit"
        return {"stage_id" => stage.id, "skipped" => true}
      end

      type3_identifier = patient.patient_identifiers
                                .find { |pi| pi.identifier_type == 3 }
                                &.identifier

      {
        "stage_id"          => stage.id,
        "visit_id"          => stage.visit_id,
        "patient_id"        => patient.patient_id,
        "stage"             => stage.stage,
        "visit_number"      => stage.visit_number,
        "program_id"        => stage.program_id,
        "disposition_type"  => stage.disposition_type,
        "patient_care_area" => stage.patient_care_area,
        "department"        => stage.department,
        "triage_result"     => stage.triage_result,
        "destination"       => stage.destination,
        "arrival_time"      => stage.arrival_time&.iso8601,
        "status"            => stage.status,
        "location_id"       => stage.location_id.to_s,
        "full_name"         => patient.name,
        "identifier"        => type3_identifier,
      }
    end

    def generate_document_id(stage)
      patient = stage.visit&.patient
      type3_identifier = patient&.patient_identifiers
                                &.find { |pi| pi.identifier_type == 3 }
                                &.identifier

      "stage_#{type3_identifier || 'unknown'}_#{stage.arrival_time&.iso8601}"
    end
  end
end

# Usage examples:
# Sync::StageSyncJob.perform_async(10)  # Very small batches for testing
# Sync::StageSyncJob.perform_async(50)  # Default batch size
# Sync::StageSyncJob.perform_async      # Use default batch size
