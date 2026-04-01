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
          .select(:encounter_id, :encounter_type, :visit_id, :provider_id, :location_id, :program_id, :encounter_datetime)
          .to_a
        return [] if encounters.empty?

        encounter_type_names = EncounterType.where(encounter_type_id: encounters.map(&:encounter_type).uniq)
          .pluck(:encounter_type_id, :name)
          .to_h

        aggregated_observations = {}
        observations_by_encounter, children_by_parent, concept_names_by_id = preload_observation_data(encounters.map(&:encounter_id))

        encounters.each do |encounter|
          encounter_type_name = encounter_type_names[encounter.encounter_type]

          unless aggregated_observations.key?(encounter_type_name)
            aggregated_observations[encounter_type_name] = {
              encounter_type: encounter.encounter_type,
              visit_id: encounter.visit_id,
              status: status,
              obs: [], 
            }
          end
          parent_observations = observations_by_encounter[encounter.encounter_id] || []

          parent_observations.each do |observation|
            obs_hash = build_observation_hash(observation, encounter, children_by_parent, concept_names_by_id)
            aggregated_observations[encounter_type_name][:obs] << obs_hash if obs_hash
          end
        end

        aggregated_observations.values
      rescue StandardError => e
        Rails.logger.error("Error extracting all observations for patient #{patient_id}: #{e.message}")
        []
      end
    end

    def preload_observation_data(encounter_ids)
      observations = Observation.unscoped
        .where(encounter_id: encounter_ids)
        .where(voided: [false, 0])
        .select(:obs_id, :obs_group_id, :encounter_id, :concept_id, :obs_datetime, :value_coded, :value_text, :value_numeric, :value_datetime)
        .to_a

      observations_by_encounter = Hash.new { |hash, key| hash[key] = [] }
      children_by_parent = Hash.new { |hash, key| hash[key] = [] }

      observations.each do |observation|
        if observation.obs_group_id.present?
          children_by_parent[observation.obs_group_id] << observation
        else
          observations_by_encounter[observation.encounter_id] << observation
        end
      end

      concept_ids = observations.map(&:concept_id).compact.uniq
      concept_names_by_id = build_concept_name_map(concept_ids)

      [observations_by_encounter, children_by_parent, concept_names_by_id]
    end

    def build_concept_name_map(concept_ids)
      return {} if concept_ids.empty?

      concept_names = {}

      ConceptName.where(concept_id: concept_ids, voided: [false, 0])
                 .order(:concept_id, :concept_name_id)
                 .pluck(:concept_id, :name)
                 .each do |concept_id, concept_name|
        concept_names[concept_id] ||= concept_name
      end

      concept_names
    end

    def build_observation_hash(observation, encounter, children_by_parent, concept_names_by_id)
      begin
        children = (children_by_parent[observation.obs_id] || []).map do |child|
          build_observation_hash(child, encounter, children_by_parent, concept_names_by_id)
        end.compact

        {
          concept_id: observation.concept_id,
          concept_name: concept_names_by_id[observation.concept_id] || '',
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
