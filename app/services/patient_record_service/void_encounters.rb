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
      record_patient_id = record[:patientID].presence || record[:patient_id].presence

      data.each do |void_request|
        reason = void_request[:reason]
        patient_id = void_request[:patient_id].presence || record_patient_id
        void_request[:patient_id] = patient_id if patient_id.present?

        unless reason.present?
          collected_errors << "Missing reason for request=#{void_request.inspect}"
          next
        end

        unless patient_id.present?
          collected_errors << "Missing patient_id for request=#{void_request.inspect}"
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
            patient_id: patient_id,
            operation_type: 'encounter.void',
            payload: void_request,
            target_type: 'Encounter'
          ) do
            # Visit History is assembled across the patient's locations, so an
            # encounter shown there may not belong to the logged-in location.
            # Remove both default scopes, while constraining the lookup to the
            # patient in this save request so an arbitrary encounter cannot be
            # voided by ID alone.
            encounter = Encounter.unscoped.where(patient_id: patient_id).find(encounter_id)

            unless encounter.voided?
              # Encounter callbacks load observations and orders through their
              # location-scoped associations. Temporarily use the encounter's
              # own location so those dependent records are voided as well.
              with_encounter_location(encounter) do
                encounter_service.void(encounter, reason)
              end
            end
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

    def with_encounter_location(encounter)
      previous_location = Location.current
      encounter_location = encounter.location
      Location.current = encounter_location if encounter_location.present?
      yield
    ensure
      Location.current = previous_location
    end
  end
end
