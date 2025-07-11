# app/services/patient_record_service/base_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class BaseSaver
    include EncounterCreation # Include shared encounter logic

    private

    def person_service
      @person_service ||= PersonService.new
    end

    def log_error(message, error)
      Rails.logger.error("#{message}: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
    end
  end
end