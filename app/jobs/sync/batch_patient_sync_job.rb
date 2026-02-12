# app/jobs/sync/batch_patient_sync_job.rb
module Sync
  class BatchPatientSyncJob
    include Sidekiq::Job
    sidekiq_options queue: :batch_sync, retry: 3

    def perform(location_id = nil, since_date = nil, batch_size = 50)
      if location_id.present?
        Rails.logger.info("Starting batch patient sync for location #{location_id}")
      else
        Rails.logger.info("Starting batch patient sync for ALL locations")
      end
      
      since_date ||= CouchdbPatientService.get_latest_encounter_date_changed
      
      # Get unique patient IDs that need syncing
      patient_ids = get_patient_ids_to_sync(location_id, since_date)
      
      total_count = patient_ids.count
      Rails.logger.info("Found #{total_count} unique patients to sync")

      return if total_count.zero?

      # Process patients in bulk batches
      sync_patients_in_bulk(patient_ids, location_id, batch_size)

      location_msg = location_id.present? ? "for location #{location_id}" : "for ALL locations"
      Rails.logger.info("Completed syncing #{total_count} patients #{location_msg}")
    end

    private

    def sync_patients_in_bulk(patient_ids, location_id, batch_size)
      total_count = patient_ids.count
      counter = 0
      
      patient_ids.each_slice(batch_size) do |batch_ids|
        # Queue bulk patient sync job (processes multiple patients in one job)
        BulkPatientRecordSyncJob.perform_async(batch_ids, { 'location_id' => location_id })
        
        counter += batch_ids.size
        Rails.logger.info("Queued bulk sync for #{counter}/#{total_count} patients") if counter % 500 == 0
      end
      
      num_jobs = (patient_ids.count.to_f / batch_size).ceil
      Rails.logger.info("Queued #{num_jobs} bulk sync jobs for #{total_count} patients (#{batch_size} patients per job)")
    end

    def get_patient_ids_to_sync(location_id, since_date)
      query = Encounter.unscoped.select(:patient_id).distinct
      
      # Add location filter if provided
      query = query.where(location_id: 1) if location_id.present?
      
      # Add date filter if provided
      if since_date.present?
        parsed_date = Time.zone.parse(since_date.to_s)
        query = query.where('encounter.date_created >= ?', parsed_date)
      end
      
      query.pluck(:patient_id)
    end
  end
end

# Usage examples:
# Sync::BatchPatientSyncJob.perform_async                          # All locations, 50 patients per batch
# Sync::BatchPatientSyncJob.perform_async(700)                     # Specific location
# Sync::BatchPatientSyncJob.perform_async(700, '2024-01-01')      # With date filter
# Sync::BatchPatientSyncJob.perform_async(nil, nil, 25)           # Smaller batches (25 patients)
# Sync::BatchPatientSyncJob.perform_async(nil, nil, 100)          # Larger batches (100 patients)
