class ClientDetailsJob < ApplicationJob
    queue_as :default
  
    BATCH_SIZE = 100  # Define the number of records to fetch per batch
  
    def perform(location_id)
      total_records = Patient.joins(:patient_programs)
                             .where("patient_program.location_id = ?", location_id)
                             .count
  
      # Fetch and broadcast in batches
      (0...total_records).step(BATCH_SIZE) do |offset|
        # Fetch a batch of patients
        patients = Patient.joins(:patient_programs)
                          .where("patient_program.location_id = ?", location_id)
                          .offset(offset)
                          .limit(BATCH_SIZE)

        # Map each patient with their details including the vaccine schedule
        patient_details = patients.map do |patient|
          details = patient.as_json
          details["vaccine_schedule"] = ImmunizationService::VaccineScheduleService.vaccine_schedule(patient)
          details
        end
  
        # Broadcast the batch with the appended vaccine schedules
        ActionCable.server.broadcast(
          "client_details_channel_#{location_id}",
          patient_details
        )
      end
    end
  end
  