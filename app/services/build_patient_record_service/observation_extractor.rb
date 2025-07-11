# frozen_string_literal: true
module BuildPatientRecordService
  module ObservationExtractor
    include ModelUtils
    def safe_extract_observations(patient_id, encounter_type, value_filters = nil, has_children = nil)
      begin
        return [] unless patient_id && encounter_type
        
        encounters = Encounter.where(patient_id: patient_id, encounter_type: encounter_type)
        return [] unless encounters.any?

        encounters.flat_map do |encounter|
          safe_process_observations(encounter, value_filters, has_children)
        end.compact
      rescue StandardError => e
        Rails.logger.error("Error extracting observations for patient #{patient_id}, encounter type #{encounter_type}: #{e.message}")
        []
      end
    end
    
    def safe_process_observations(encounter, value_filters, has_children)
      begin
        encounter.observations
                .select do |observation|
                  if value_filters
                    safe_matches_filters?(observation, value_filters)
                  else
                    !has_children || observation.children.length.positive?
                  end
                end
                .map do |observation|
          safe_build_observation_hash(observation, encounter)
        end.compact
      rescue StandardError => e
        Rails.logger.error("Error processing observations for encounter #{encounter.id}: #{e.message}")
        []
      end
    end
    
    def safe_matches_filters?(observation, filters)
      begin
        return true if filters.nil? || filters.empty?

        filters.any? do |field, value|
          observation.respond_to?(field) && observation.send(field) == value
        end
      rescue StandardError => e
        Rails.logger.error("Error matching filters: #{e.message}")
        false
      end
    end

    def safe_build_observation_hash(observation, encounter)
      begin
        children = observation.children.map { |child| safe_build_observation_hash(child, encounter) }
    
        {
          concept_id: observation.concept_id,
          concept_name: safe_concept_id_to_name(observation.concept_id),
          obs_datetime: observation.obs_datetime&.to_s,
          obs_id: observation.obs_id,
          children: children,
          value_coded: observation.value_coded,
          value_text: observation.value_text || '',
          value_numeric: observation.value_numeric,
          provider_id: encounter.provider_id,
          location_id: encounter.location_id,
          program_id: encounter.program_id,
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