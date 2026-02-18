# app/jobs/sync/stage_sync_job.rb
module Sync
  class StageSyncJob < BaseSyncJob
    # Sync all stages to CouchDB
    def perform(batch_size = 50)
      # Build the complex query with joins
      query = Stage.includes(patient: :patient_identifiers)
                   .joins(:visit)
                   .joins('INNER JOIN patient ON patient.patient_id = visit.patient_id')
                   .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')

      # Use the same query for counting
      count_query = query

      sync_custom_query_to_couchdb(
        query,
        count_query, 
        'stages',
        'stages',
        batch_size,
        progress_interval: 10,
        rate_limit_interval: 5
      )
    end

    private

    def prepare_document(stage)
      # Get type3_identifier for this stage
      type3_identifier = stage.patient.patient_identifiers.find { |pi| pi.identifier_type == 3 }&.identifier
      
      # Skip if no type3_identifier found
      if type3_identifier.blank?
        Sidekiq.logger.warn "Skipping stage ID #{stage.id}: No type3_identifier found"
        return nil # This will be handled by the base class
      end

      {
        "stage_id" => stage.id,
        "visit_id" => stage.visit_id,
        "patient_id" => stage.patient_id,
        "stage" => stage.stage,
        "arrivalTime" => stage.arrival_time&.iso8601,
        "arrival_time" => stage.arrival_time&.iso8601,
        "status" => stage.status,
        "location_id" => stage.location_id,
        "fullName" => stage.patient.name,
        "identifier" => type3_identifier,
      }
    end

    def generate_document_id(stage)
      # Get type3_identifier for document ID
      type3_identifier = stage.patient.patient_identifiers.find { |pi| pi.identifier_type == 3 }&.identifier
      type3_identifier || "stage_#{stage.id}" # Fallback to stage ID if no identifier
    end
  end
end

# Usage examples:
# Sync::StageSyncJob.perform_async(10)  # Very small batches for testing
# Sync::StageSyncJob.perform_async(50)  # Default batch size
# Sync::StageSyncJob.perform_async      # Use default batch size
