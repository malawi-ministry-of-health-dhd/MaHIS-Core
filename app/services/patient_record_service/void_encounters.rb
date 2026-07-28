# app/services/patient_record_service/void_encounters.rb
# frozen_string_literal: true

module PatientRecordService
  class VoidEncounters < BaseSaver
    # Client-side operation type used when an unsaved observation encounter is
    # pushed for creation. The receipt it leaves behind is how we map a client
    # operation_id back to the Encounter the listener created for it.
    OBSERVATION_ENCOUNTER_OPERATION_TYPE = 'observation_encounter.create'

    def void_encounters(record)
      data = record.dig(:void_encounters)
      return ok unless data.is_a?(Array) && data.any?

      collected_errors = []

      data.each do |void_request|
        reason = void_request[:reason]

        unless reason.present?
          collected_errors << "Missing reason for request=#{void_request.inspect}"
          next
        end

        encounter_id = void_request[:id].presence || resolve_encounter_id_from_receipt(void_request)
        # Write the resolved id back so the record rebuild downstream refreshes
        # this encounter's type (it reads void_encounters[].id).
        void_request[:id] = encounter_id if encounter_id.present?

        # An unsaved encounter that never reached MySQL has no receipt to resolve.
        # The client already dropped it from the record, so there is nothing to void.
        next if encounter_id.blank? && void_request[:encounter_operation_id].present?

        unless encounter_id.present?
          collected_errors << "Missing encounter_id or encounter_operation_id for request=#{void_request.inspect}"
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

    # An encounter voided while still in the "unsaved" state carries no
    # encounter_id, only the operation_id the client stamped on the observation
    # group. If the listener already turned that group into an Encounter, the
    # operation receipt holds the resulting encounter_id.
    def resolve_encounter_id_from_receipt(void_request)
      operation_id = void_request[:encounter_operation_id]
      return nil if operation_id.blank?

      scope = PatientRecordOperationReceipt.where(
        operation_type: OBSERVATION_ENCOUNTER_OPERATION_TYPE,
        operation_id: operation_id,
        status: 'completed',
        target_type: 'Encounter'
      )
      patient_id = void_request[:patient_id]
      scope = scope.where(patient_id: patient_id) if patient_id.present?

      scope.order(completed_at: :desc).first&.target_id.presence
    end

    def encounter_service
      @encounter_service ||= EncounterService.new
    end
  end
end
