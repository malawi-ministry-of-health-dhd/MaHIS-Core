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

    def with_operation_guard(patient_id:, operation_type:, payload:, operation_id: nil, target_type: nil, &block)
      PatientRecordOperationGuard.run!(
        patient_id: patient_id,
        operation_type: operation_type,
        operation_id: operation_id,
        payload: payload,
        target_type: target_type,
        &block
      )
    end

    def operation_value_for(container, key)
      return nil if container.nil? || !container.respond_to?(:[])

      container[key] || container[key.to_s]
    rescue TypeError
      nil
    end
  end
end
