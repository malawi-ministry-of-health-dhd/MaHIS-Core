class PatientRecordSyncJob
  include Sidekiq::Job
  
  sidekiq_options queue: :patient_sync, retry: 3
  
  def perform(patient_id, options = {})
    # Get options
    location_id = options['location_id']
    
    begin
      # Find or initialize the record in MongoDB
      patient_record = PatientRecord.find_or_initialize_by(patient_id: patient_id)
      
      # Log start of processing
      Rails.logger.info("Starting sync for patient #{patient_id}")
      
      # Get patient data with defensive error handling
      patient_data = safely_build_patient_record(patient_id)
      
      # If we couldn't build valid patient data, mark as failed and return
      if patient_data.nil?
        Rails.logger.error("Failed to build data for patient #{patient_id}")
        patient_record.update(sync_status: 'failed', last_sync_at: Time.current)
        return
      end
      
      # Update the record
      patient_record.record = patient_data
      patient_record.last_sync_at = Time.current
      patient_record.sync_status = 'synced'
      patient_record.save!
      
      Rails.logger.info("Successfully synced patient record #{patient_id}")
    rescue StandardError => e
      # Update the status to failed if the record exists
      if patient_record&.persisted?
        patient_record.update(sync_status: 'failed', last_sync_at: Time.current)
      end
      
      Rails.logger.error("Error syncing patient record #{patient_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end
  
  private
  
  def safely_build_patient_record(patient_id)
    begin
      # First check if the patient exists
      unless Patient.where(patient_id: patient_id).exists?
        Rails.logger.error("Patient #{patient_id} does not exist")
        return nil
      end
      
      # Get the raw patient data with a rescue block around the whole thing
      raw_data = BuildPatientRecordService.build_patient_record(patient_id)
      
      # Convert the data to a safe, serializable format
      sanitize_for_mongodb(raw_data)
    rescue StandardError => e
      Rails.logger.error("Error building patient record #{patient_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      nil
    end
  end
  
  # Sanitize data to ensure it can be stored in MongoDB
  def sanitize_for_mongodb(data)
    case data
    when Hash
      result = {}
      data.each do |key, value|
        # Skip nil values to prevent errors
        next if value.nil?
        result[key] = sanitize_for_mongodb(value)
      end
      result
    when Array
      data.map { |item| sanitize_for_mongodb(item) }.compact
    when ActiveRecord::Base
      # Convert ActiveRecord objects to plain hashes
      data.as_json
    when ActiveRecord::Associations::CollectionProxy
      # Convert collection proxies to arrays of hashes
      data.map(&:as_json).compact
    when Date, DateTime
      # Convert dates to ISO 8601 strings
      data.iso8601
    when Time
      # Convert times to ISO 8601 strings
      data.iso8601
    when Symbol
      # Convert symbols to strings
      data.to_s
    when Numeric, String, true, false
      # These types are safe for MongoDB
      data
    else
      # For any other type, convert to string representation
      data.to_s
    end
  rescue StandardError => e
    # If we can't sanitize this value, log the error and return nil
    Rails.logger.error("Error sanitizing value #{data.class.name}: #{e.message}")
    nil
  end
end