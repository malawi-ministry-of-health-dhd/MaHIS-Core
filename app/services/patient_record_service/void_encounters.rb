# app/services/patient_record_service/void_encounters.rb
# frozen_string_literal: true

module PatientRecordService
  class VoidEncounters < BaseSaver
    def void_encounters(record)
      data = record.dig(:void_encounters)
      return ok unless data.is_a?(Array) && data.any?

      collected_errors = []

      data.each do |void_request|
        encounter_id = void_request[:id]
        reason       = void_request[:reason]

        unless encounter_id.present? && reason.present?
          collected_errors << "Missing encounter_id or reason for request=#{void_request.inspect}"
          next
        end

        begin
          result = with_operation_guard(
            patient_id: void_request[:patient_id],
            operation_type: 'encounter.void',
            payload: void_request,
            target_type: 'Encounter'
          ) do
            encounter = Encounter.find(encounter_id)
            encounter_service.void(encounter, reason)
            { target_type: 'Encounter', target_id: encounter_id }
          end

          next if result.skipped?
        rescue ActiveRecord::RecordNotFound => e
          collected_errors << "Encounter #{encounter_id} not found: #{e.message}"
          Rails.logger.error("Failed to void encounter #{encounter_id}: #{e.message}")
        rescue StandardError => e
          collected_errors << "Encounter #{encounter_id}: #{e.message}"
          Rails.logger.error("Failed to void encounter #{encounter_id}: #{e.message}")
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    end

    private

    def encounter_service
      @encounter_service ||= EncounterService.new
    end
  end
end
