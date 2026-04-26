# app/services/patient_record_service/observation_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class ObservationSaver < BaseSaver
    def save_all_observations(patient_id, record)
      data = record.dig(:observations)
      return ok unless data&.any?

      unsaved_items = data.select { |item| item.present? && item[:status] == "unsaved" && item[:obs]&.any? }
      return ok if unsaved_items.empty?

      collected_errors = []

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

            item[:obs].each do |archetype|
              archetype[:location_id] = record[:location_id]
              params = archetype.respond_to?(:permit!) ? archetype.permit! : archetype

              begin
                observation_service.create_observation(encounter, params)
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
      return nil unless container.respond_to?(:[])

      container[key] || container[key.to_s]
    end
  end
end
