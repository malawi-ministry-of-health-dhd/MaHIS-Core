# app/services/patient_record_service/base_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class BaseSaver
    include EncounterCreation

    private

    def person_service
      @person_service ||= PersonService.new
    end

    def ok
      OperationResult.ok
    end

    def fail(*errors)
      OperationResult.fail(*errors)
    end

    def log_and_fail(context, exception)
      log_error(context, exception)
      OperationResult.fail("#{context}: #{exception.message}")
    end

    def log_error(message, error)
      Rails.logger.error("#{message}: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
    end
  end
end