class NcdActiveClientsJob
  include Sidekiq::Job
  sidekiq_options queue: :ncd_active_patients, retry: 3

  def perform(*args)
    Rails.logger.info("Starting NCD active patients sync")
    begin
      find_active_clients()
      Rails.logger.info("Successfully synced NCD active patients")
    rescue StandardError => e
      Rails.logger.error("Error syncing NCD active patients: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise # Re-raise to trigger Sidekiq retry mechanism
    end
  end

  private

  def find_active_clients()
    Rails.logger.info("Finding active clients")
    service = FacilityService.new
    result = service.list_facility_codes()
    Rails.logger.info("Found #{result.count} facilities")
    
    result.each do |facility|
      Rails.logger.info("Processing facility: #{facility}")
      begin
        ncd_active_patients(facility)
      rescue StandardError => e
        Rails.logger.error("Error processing facility #{facility}: #{e.message}")
        # Continue processing other facilities instead of failing the entire job
      end
    end
  end

  def ncd_active_patients(location_id)
    Rails.logger.info("Processing NCD patients for location: #{location_id}")
    
    @current_date = Date.current
    @location_id = location_id

    base_patients = Patient.joins(encounters: [:program, :type])
                          .where(program: { program_id: 32 })
                          .where(encounters: { location_id: @location_id })
                          .where(encounter_type: { name: ['PATIENT REGISTRATION', 'REGISTRATION'] })
                          .distinct
    
    patient_count = base_patients.count
    Rails.logger.info("Found #{patient_count} patients for location #{location_id}")
    
    if patient_count > 0
      MongoSyncService.new.sync_patients_to_mongo(base_patients, @location_id)
      Rails.logger.info("Successfully synced #{patient_count} patients to MongoDB for location #{location_id}")
    else
      Rails.logger.info("No patients found for location #{location_id}")
    end
  end
end