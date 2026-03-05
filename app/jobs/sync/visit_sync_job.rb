# app/jobs/sync/visit_sync_job.rb
module Sync
  class VisitSyncJob < BaseSyncJob
    
    def perform(batch_size = 50)
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
      Visit.select(
          'visit.visit_id, visit.patient_id, visit.date_started, visit.date_stopped, '\
          'visit.location_id, patient_identifier.identifier AS identifier, '\
          'MIN(encounter.program_id) AS program_id'
        )
        .joins('INNER JOIN encounter ON encounter.visit_id = visit.visit_id')
        .joins('INNER JOIN patient ON patient.patient_id = visit.patient_id')
        .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')
        .group('visit.visit_id, patient_identifier.identifier')
    end
    
    def get_visits_count_query
      # Wrap in a subquery so .count returns a plain integer, not a Hash
      Visit.from(
        Visit.select('visit.visit_id')
          .joins('INNER JOIN encounter ON encounter.visit_id = visit.visit_id')
          .joins('INNER JOIN patient ON patient.patient_id = visit.patient_id')
          .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')
          .group('visit.visit_id, patient_identifier.identifier'),
        :visit
      )
    end
    
    def prepare_document(visit)
      {
        "visit_id"     => visit.visit_id,
        "patient_id"   => visit.patient_id,
        "identifier"   => visit.try(:identifier),
        "full_name"    => visit.patient.try(:name),
        "program_id"   => visit.try(:program_id),
        "date_started" => visit.date_started&.iso8601,
        "date_stopped" => visit.date_stopped&.iso8601,
        "location_id"  => visit.location_id,
      }
    end
    
    def generate_document_id(visit)
      identifier = visit.try(:identifier) || 'unknown'
      start_date = visit.date_started ? visit.date_started.to_time.strftime("%Y-%m-%dT%H:%M:%S") : 'no-date'
      "#{identifier}_#{start_date}"
    end
  end
end