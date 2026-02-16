# frozen_string_literal: true
module BuildPatientRecordService
  module ObservationExtractor
    include ModelUtils
    def build_all_observations(patient_id, allowed_encounter_types = nil, status = "saved")
      begin
        return [] unless patient_id

        encounters_query = Encounter.unscoped.where(patient_id: patient_id)

        if allowed_encounter_types.is_a?(Array) && allowed_encounter_types.any?
          encounters_query = encounters_query.where(encounter_type: allowed_encounter_types)
        end

        encounters = encounters_query
        return [] unless encounters.any?

        aggregated_observations = {}

        encounters.each do |encounter|
          encounter_type_name = EncounterType.where(encounter_type_id: encounter.encounter_type).pick(:name)

          unless aggregated_observations.key?(encounter_type_name)
            aggregated_observations[encounter_type_name] = {
              encounter_type: encounter.encounter_type,
              status: status,
              obs: [], 
            }
          end
          
          parent_observations = encounter.observations.where(obs_group_id: nil)
          
          parent_observations.each do |observation|
            obs_hash = safe_build_observation_hash(observation, encounter)
            aggregated_observations[encounter_type_name][:obs] << obs_hash if obs_hash
          end
        end

        aggregated_observations.values
      rescue StandardError => e
        Rails.logger.error("Error extracting all observations for patient #{patient_id}: #{e.message}")
        []
      end
    end

    def safe_build_observation_hash(observation, encounter)
      begin
        children = observation.children.map { |child| safe_build_observation_hash(child, encounter) }.compact

        {
          concept_id: observation.concept_id,
          concept_name: safe_concept_id_to_name(observation.concept_id),
          obs_datetime: observation.obs_datetime&.to_s,
          obs_id: observation.obs_id,
          children: children,
          value_coded: observation.value_coded,
          value_text: observation.value_text || '',
          value_numeric: observation.value_numeric,
          value_datetime: observation.value_datetime,
          provider_id: encounter.provider_id,
          location_id: encounter.location_id,
          program_id: encounter.program_id,
          encounter_id: encounter.encounter_id,
          encounter_datetime: encounter.encounter_datetime,
        }
      rescue StandardError => e
        Rails.logger.error("Error building observation hash for obs #{observation.id}: #{e.message}")
        nil 
      end
    end

    def safe_concept_id_to_name(concept_id)
      begin
        return '' unless concept_id
        concept_id_to_name(concept_id)
      rescue StandardError => e
        Rails.logger.error("Error converting concept ID #{concept_id} to name: #{e.message}")
        ''
      end
    end
  end
end