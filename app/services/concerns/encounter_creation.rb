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
      encounter = encounter_service.create(
        type: EncounterType.find(encounter_type_id),
        patient: Patient.find(patient_id),
        program: Program.find(record[:program_id]),
        provider: record[:provider_id] ? Person.find(record[:provider_id]) : User.current.person,
        encounter_datetime: TimeUtils.retro_timestamp(record[:encounter_datetime]&.to_time || Time.now),
        location_id: record[:location_id] || Location.current.id
      )
      encounter.encounter_id
    end

    def save_obs(encounter_id:, observations:, location_id: nil)
      encounter = Encounter.find(encounter_id)
      observations.map do |archetype|
        archetype[:location_id] = location_id
        service = ObservationService.new
        service.create_observation(encounter, archetype.permit!)
      end
    end

    def observation_service
      @observation_service ||= ObservationService.new
    end
  end
end