# app/services/patient_record_service/observation_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class ObservationSaver < BaseSaver
    def save_all_observations(patient_id, record)
      data = record.dig(:observations)
      return false unless data&.any?

      # Check if there are any items with "unsaved" status
      unsaved_items = data.select { |item| item.present? && item[:status] == "unsaved" && item[:obs]&.any? }
      return false if unsaved_items.empty?

      begin
        ActiveRecord::Base.transaction do
          unsaved_items.each do |item|
            encounter_type = EncounterType.find_by_encounter_type_id(item[:encounter_type])
            next unless encounter_type

            encounter_id = create_encounter(patient_id, encounter_type.id, item)
            encounter = Encounter.find(encounter_id)
            item[:obs].map do |archetype|
              archetype[:location_id] = record[:location_id]
              params = archetype.respond_to?(:permit!) ? archetype.permit! : archetype
              observation_service.create_observation(encounter, params)
            end
          end
        end
        return true
      rescue StandardError => e
        log_error("Error saving observations", e)
        return false  
      end
    end
  end
end