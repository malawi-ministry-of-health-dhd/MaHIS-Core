# app/jobs/sync/visit_sync_job.rb
module Sync
  class VisitSyncJob < BaseSyncJob
    
    # Sync all visits to CouchDB
    def perform(batch_size = 50)
      # Use the custom query sync method
      sync_custom_query_to_couchdb(
        get_visits_with_identifiers,
        get_visits_count_query,
        'visits',
        'visit',
        batch_size,
        progress_interval: 25,
        rate_limit_interval: 10
      )
    end
    
    private
    
    def get_visits_with_identifiers
      Visit.includes(:patient)
        .select('visits.*, patient_identifier.identifier AS identifier')
        .joins('INNER JOIN patient ON patient.patient_id = visits.patient_id')
        .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')
    end
    
    def get_visits_count_query
      Visit.joins('INNER JOIN patient ON patient.patient_id = visits.patient_id')
        .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')
    end
    
    def prepare_document(visit)
      {
        "type" => "visit",
        "visit_id" => visit.id,
        "patient_id" => visit.patient_id,
        "identifier" => visit.try(:identifier),
        "fullName" => visit.patient.try(:name),
        "date_started" => visit.date_started&.iso8601,
        "date_stopped" => visit.date_stopped&.iso8601,
        "programId" => visit.programId,
        "location_id" => visit.location_id,
        "created_at" => visit.created_at&.iso8601,
        "updated_at" => visit.updated_at&.iso8601,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(visit)
      # Create composite _id from identifier and start_date
      identifier = visit.try(:identifier) || 'unknown'
      start_date = visit.date_started ? visit.date_started.to_time.strftime("%Y-%m-%dT%H:%M:%S") : 'no-date'
      "#{identifier}_#{start_date}"
    end
  end
end

# Usage examples:
# Sync::VisitSyncJob.perform_async(25)  # Smaller batches for testing
# Sync::VisitSyncJob.perform_async(50)  # Default batch size
# Sync::VisitSyncJob.perform_async(100) # Larger batches for faster sync