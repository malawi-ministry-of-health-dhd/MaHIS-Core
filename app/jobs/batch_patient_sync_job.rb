class BatchPatientSyncJob
  include Sidekiq::Job
  
  sidekiq_options queue: :batch_sync, retry: 3
  
  def perform(location_id = nil, since_date = nil)
    if location_id.present?
      Rails.logger.info("Starting batch patient sync for location #{location_id}")
    else
      Rails.logger.info("Starting batch patient sync for ALL locations")
    end
    
    # Build query to get patient that need syncing
    query = Patient.joins(:encounters)
                   .select('patient.patient_id')
                   .distinct
    
    # Add location filter if provided
    query = query.where(encounters: { location_id: location_id }) if location_id.present?
    
    # Add date filter if provided
    if since_date.present?
      parsed_date = Time.zone.parse(since_date.to_s)
      query = query.where('encounters.date_created >= ?', parsed_date)
    end
    
    # Get total count for logging
    total_count = query.count
    Rails.logger.info("Found #{total_count} patient to sync")
    
    # Process in batches to avoid memory issues
    counter = 0
    query.find_in_batches(batch_size: 100) do |group|
      group.each do |patient|
        # Queue individual sync jobs
        PatientRecordSyncJob.perform_async(
          patient.patient_id, 
          { 'location_id' => location_id }
        )
        counter += 1
      end
      
      # Log progress
      Rails.logger.info("Queued #{counter}/#{total_count} patient sync jobs")
    end
    
    location_msg = location_id.present? ? "for location #{location_id}" : "for ALL locations"
    Rails.logger.info("Completed queuing batch patient sync #{location_msg}")
  end
end