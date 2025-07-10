# frozen_string_literal: true
module BuildPatientRecordService
  module VaccineService
    def safe_get_vaccine_schedule(person)
      begin
        return [] unless person
        ImmunizationService::VaccineScheduleService.vaccine_schedule(person)
      rescue StandardError => e
        Rails.logger.error("Error getting vaccine schedule: #{e.message}")
        []
      end
    end
  end
end

