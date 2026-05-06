# app/services/patient_record_service/observation_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class ObservationSaver < BaseSaver
    NCD_PROGRAM_ID = 32
    PRIMARY_DIAGNOSIS_CONCEPT_NAME = "primary diagnosis".freeze
    DIABETES_DIAGNOSIS_CONCEPT_NAMES = [
      "type 1 diabetes mellitus",
      "type 2 diabetes mellitus"
    ].freeze
    HYPERTENSION_DIAGNOSIS_CONCEPT_NAME = "hypertension".freeze
    OBSERVATION_PAYLOAD_KEYS = %i[
      concept_id concept_name value_boolean value_numeric value_drug
      value_coded value_datetime value_text obs_datetime child children
    ].freeze
    OBSERVATION_VALUE_KEYS = %i[
      value_boolean value_numeric value_drug value_coded value_datetime value_text
    ].freeze

    def save_all_observations(patient_id, record)
      data = record.dig(:observations)
      return ok unless data&.any?

      unsaved_items = data.select { |item| item.present? && item[:status] == "unsaved" && normalized_observations(item[:obs]).any? }
      return ok if unsaved_items.empty?

      collected_errors = []
      sent_confirmed_diagnoses = {}

      unsaved_items.each do |item|
        encounter_type = EncounterType.find_by_encounter_type_id(item[:encounter_type])
        unless encounter_type
          collected_errors << "Unknown encounter_type id=#{item[:encounter_type]}"
          next
        end

        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            encounter_id = create_encounter(patient_id, encounter_type.id, item)
            encounter    = Encounter.find(encounter_id)

            normalized_observations(item[:obs]).each do |archetype|
              begin
                params = to_permitted_params(archetype)
                params[:location_id] = record[:location_id]
                unless observation_value_present?(params)
                  Rails.logger.warn("Skipping empty observation payload for encounter #{encounter_id}: #{format_observation_reference(params)}")
                  next
                end

                confirmed_diagnosis = confirmed_ncd_diagnosis(record, params)
                observation_service.create_observation(encounter, params)
                if confirmed_diagnosis && !sent_confirmed_diagnoses[confirmed_diagnosis]
                  FhirService.sendConfirmedDiagnosisToMediator(patient_id, confirmed_diagnosis)
                  sent_confirmed_diagnoses[confirmed_diagnosis] = true
                end
              rescue StandardError => e
                log_error("Error saving obs for encounter #{encounter_id}", e)
                collected_errors << "Encounter #{encounter_type.name}, obs #{format_observation_reference(archetype)}: #{e.message}"
                # continues to next obs
              end
            end
          end
        rescue StandardError => e
          log_error("Error creating encounter for type #{encounter_type.name}", e)
          collected_errors << "Encounter #{encounter_type.name}: #{e.message}"
          # continues to next item
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    end

    private

    def normalized_observations(payload)
      return [] if payload.blank?
      return [payload] if observation_payload?(payload)

      if payload.respond_to?(:values)
        return payload.values.flat_map { |item| normalized_observations(item) }
      end

      if payload.respond_to?(:to_a) && !payload.is_a?(String)
        return payload.to_a.flat_map { |item| normalized_observations(item) }
      end

      []
    end

    def observation_payload?(payload)
      return false if payload.is_a?(String) || payload.is_a?(Numeric)
      return false unless payload.respond_to?(:[])

      OBSERVATION_PAYLOAD_KEYS.any? { |key| value_for(payload, key).present? }
    end

    def observation_value_present?(payload)
      OBSERVATION_VALUE_KEYS.any? { |key| value_for(payload, key).present? }
    end

    def confirmed_ncd_diagnosis(record, archetype)
      return nil unless ncd_program?(record)
      return nil unless primary_diagnosis_observation?(archetype)

      value_coded = value_for(archetype, :value_coded)
      return nil if value_coded.blank?

      value_coded_id = value_coded.to_i
      diagnosis_names = concept_names_for(value_coded_id).map { |name| normalize_concept_name(name) }

      return "Diabetes" if diabetes_diagnosis?(diagnosis_names)
      return "Hypertension" if hypertension_diagnosis?(diagnosis_names)

      nil
    end

    def ncd_program?(record)
      value_for(record, :program_id).to_s.to_i == NCD_PROGRAM_ID
    end

    def primary_diagnosis_observation?(archetype)
      concept_name = normalize_concept_name(value_for(archetype, :concept_name))
      return true if concept_name == PRIMARY_DIAGNOSIS_CONCEPT_NAME

      concept_id = value_for(archetype, :concept_id).to_s.to_i
      concept_names_for(concept_id).any? do |name|
        normalize_concept_name(name) == PRIMARY_DIAGNOSIS_CONCEPT_NAME
      end
    end

    def diabetes_diagnosis?(diagnosis_names)
      diagnosis_names.any? { |name| DIABETES_DIAGNOSIS_CONCEPT_NAMES.include?(name) }
    end

    def hypertension_diagnosis?(diagnosis_names)
      diagnosis_names.any? { |name| name.include?(HYPERTENSION_DIAGNOSIS_CONCEPT_NAME) }
    end

    def concept_names_for(concept_id)
      return [] if concept_id.blank? || concept_id.to_i <= 0

      @concept_names_cache ||= {}
      @concept_names_cache[concept_id] ||= ConceptName.where(concept_id: concept_id, voided: 0).pluck(:name).compact
    end

    def normalize_concept_name(name)
      name.to_s.downcase.squish
    end

    def format_observation_reference(archetype)
      concept_id = value_for(archetype, :concept_id)
      payload_concept_name = value_for(archetype, :concept_name).to_s.strip
      concept_name = payload_concept_name.presence || concept_name_for(concept_id)

      return concept_name if concept_name.present?
      return "concept_id=#{concept_id}" if concept_id.present?

      "unknown concept"
    end

    def concept_name_for(concept_id)
      return nil if concept_id.blank?

      @concept_name_cache ||= {}
      @concept_name_cache[concept_id] ||= ConceptName.where(concept_id: concept_id, voided: 0).order(:concept_name_id).limit(1).pick(:name)
    end

    def value_for(container, key)
      return nil if container.is_a?(String) || container.is_a?(Numeric)
      return nil unless container.respond_to?(:[])

      container[key] || container[key.to_s]
    rescue TypeError
      nil
    end
  end
end
