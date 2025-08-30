# app/jobs/sync/batch_patient_sync_job.rb
module Sync
  class BatchPatientSyncJob < BaseSyncJob
    sidekiq_options queue: :batch_sync, retry: 3
    
    # Sync patients in batches by location and date
    def perform(location_id = nil, since_date = nil)
      if location_id.present?
        Sidekiq.logger.info("Starting batch patient sync for location #{location_id}")
      else
        Sidekiq.logger.info("Starting batch patient sync for ALL locations")
      end
      
      # Get unique patient IDs that need syncing
      patient_ids = get_patient_ids_to_sync(location_id, since_date)
      
      # Use the base class array sync method
      sync_array_to_couchdb(patient_ids, 'patients_records', 'patients', 100, 
                           progress_interval: 100, rate_limit_interval: 10) do |patient_id|
        # Custom processing: queue individual sync jobs instead of direct sync
        queue_patient_sync_job(patient_id, location_id)
      end
      
      location_msg = location_id.present? ? "for location #{location_id}" : "for ALL locations"
      Sidekiq.logger.info("Completed queuing #{patient_ids.length} batch patient sync jobs #{location_msg}")
    end
    
    private
    
    def get_patient_ids_to_sync(location_id, since_date)
      # Build base query for patient IDs
      query = Patient.joins(:encounters)
                     .select('patients.patient_id')
                     .distinct
      
      # Add location filter if provided
      if location_id.present?
        query = query.where(encounters: { location_id: location_id })
      end
      
      # Add date filter if provided
      if since_date.present?
        parsed_date = Time.zone.parse(since_date.to_s)
        query = query.where('encounters.date_created >= ?', parsed_date)
      end
      
      # Return array of patient IDs to avoid issues with complex joined queries
      query.pluck(:patient_id).uniq
    end
    
    def queue_patient_sync_job(patient_id, location_id)
      # Queue individual sync jobs instead of syncing directly
      PatientRecordSyncJob.perform_async(
        patient_id,
        { 'location_id' => location_id }
      )
    end
    
    # Override the base class sync method since we're queuing jobs instead of syncing directly
    def sync_record_to_couchdb(patient_id, db_name)
      queue_patient_sync_job(patient_id, nil)
    end
    
    # These methods are required by base class but not used in this job pattern
    def prepare_document(patient_id)
      { patient_id: patient_id }
    end
    
    def generate_document_id(patient_id)
      "patient_queue_#{patient_id}"
    end
  end
end

# Batch sync all patients:
# Sync::BatchPatientSyncJob.perform_async

# Batch sync by location:
# Sync::BatchPatientSyncJob.perform_async(700)

# Batch sync by location and date:
# Sync::BatchPatientSyncJob.perform_async(700, '2024-01-01')