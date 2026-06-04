# app/services/concerns/encounter_creation.rb
# frozen_string_literal: true

module EncounterCreation
  extend ActiveSupport::Concern

  included do
    # You might want to make these private and expose them via a service object
    # or have the calling service pass in the encounter_id directly.
    # For now, let's keep them as instance methods.
    def create_encounter(patient_id, encounter_type_id, record)
      encounter_service = EncounterService.new
      program_id = record_value(record, :program_id)
      provider_id = record_value(record, :provider_id)
      encounter_datetime = record_value(record, :encounter_datetime)
      location_id = record_value(record, :location_id)

      encounter = encounter_service.create(
        type: EncounterType.find(encounter_type_id),
        patient: Patient.find(patient_id),
        program: Program.find(program_id),
        provider: provider_id ? User.find(provider_id)&.person : User.current.person,
        encounter_datetime: TimeUtils.retro_timestamp(encounter_datetime&.to_time || Time.now),
        location_id: location_id || Location.current.id
      )
      encounter.encounter_id
    end

    def save_obs(encounter_id:, observations:, location_id: nil)
      encounter = Encounter.find(encounter_id)

      observations.map do |archetype|
        archetype[:location_id] = location_id
        safe_params = to_permitted_params(archetype)
        ObservationService.new.create_observation(encounter, safe_params)
      end
    end

    def to_permitted_params(hash_or_params)
      case hash_or_params
      when ActionController::Parameters
        hash_or_params.permit!
      else
        ActionController::Parameters.new(hash_or_params).permit!
      end
    end

    def observation_service
      @observation_service ||= ObservationService.new
    end

    def record_value(container, key)
      return nil if container.nil? || !container.respond_to?(:[])

      container[key] || container[key.to_s]
    rescue TypeError
      nil
    end
  end
end
