# app/services/patient_record_service/vaccine_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class VaccineManager < BaseSaver
    ENCOUNTER_TYPE_MAPPING = SavePatientRecordService::ENCOUNTER_TYPE_MAPPING

    def save_vaccines(patient_id, record)
      orders = record.dig(:vaccineAdministration, :orders)
      return ok unless orders&.any?

      collected_errors = []
      encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:treatment])

      unless encounter_type
        return OperationResult.new(success: true, errors: ["Encounter type #{ENCOUNTER_TYPE_MAPPING[:treatment]} not found"])
      end

      orders.each do |order|
        begin
          result = with_operation_guard(
            patient_id: patient_id,
            operation_type: 'vaccine_order.create',
            payload: order,
            target_type: 'Order'
          ) do
            ActiveRecord::Base.transaction(requires_new: true) do
              encounter_id = create_encounter(patient_id, encounter_type.id, record)
              obs = build_drugs_dispensed_observation(order, record)

              AdministerVaccineService.administer_vaccine(
                encounter_id, [order], record[:program_id], [obs],
                record[:provider_id], record[:location_id]
              )

              saved_order = Order.where(encounter_id: encounter_id, voided: 0).order(order_id: :desc).first
              raise StandardError, "Vaccine order was not created for #{value_for(order, :drug_name)}" unless saved_order

              ensure_drugs_dispensed_observation!(encounter_id, order, obs, record, saved_order.order_id)

              { target_type: 'Order', target_id: saved_order.order_id }
            end
          end

          next if result.skipped?
        rescue StandardError => e
          log_error("Failed to save vaccine order #{order[:drug_name]}", e)
          collected_errors << "Vaccine #{order[:drug_name]}: #{e.message}"
          # continues to next order
        end
      end

      record[:vaccineAdministration][:obs]    = []
      record[:vaccineAdministration][:orders] = []

      OperationResult.new(success: true, errors: collected_errors)
    end

    def void_vaccine(_patient_id, record)
      data = record.dig(:vaccineAdministration, :voided)
      return ok unless data&.any?

      collected_errors = []

      data.each do |item|
        begin
          result = with_operation_guard(
            patient_id: _patient_id,
            operation_type: 'vaccine_order.void',
            payload: item,
            target_type: 'Order'
          ) do
            ActiveRecord::Base.transaction(requires_new: true) do
              order = Order.find(item[:order_id])
              order.void(item[:reason])
              Observation.where(order_id: order.id).each { |obs| obs.void(item[:reason]) }
              { target_type: 'Order', target_id: order.order_id }
            end
          end

          next if result.skipped?
        rescue ActiveRecord::RecordNotFound => e
          log_error("Order not found for void", e)
          collected_errors << "Order #{item[:order_id]}: #{e.message}"
        rescue StandardError => e
          log_error("Error voiding vaccine", e)
          collected_errors << "Order #{item[:order_id]}: #{e.message}"
        end
      end

      record[:vaccineAdministration][:voided] = []
      OperationResult.new(success: true, errors: collected_errors)
    end

    private

    def build_drugs_dispensed_observation(order, record)
      concept_id = ConceptName.find_by_name('Drugs dispensed')&.concept_id
      raise StandardError, 'Concept "Drugs dispensed" not found' unless concept_id

      source_obs = record.dig(:vaccineAdministration, :obs)&.find do |item|
        value_for(item, :value_text).to_s.strip.casecmp?(value_for(order, :drug_name).to_s.strip)
      end

      {
        concept_id: concept_id,
        value_text: value_for(order, :drug_name),
        obs_datetime: value_for(source_obs, :obs_datetime) || value_for(order, :start_date)
      }
    end

    def value_for(container, key)
      return nil unless container.respond_to?(:[])

      container[key] || container[key.to_s]
    end

    def ensure_drugs_dispensed_observation!(encounter_id, order, obs_payload, record, order_id)
      concept_id = value_for(obs_payload, :concept_id)
      return unless concept_id

      drug_name = value_for(order, :drug_name).to_s.strip
      return if drug_name.blank?

      existing_observation = Observation.where(
        encounter_id: encounter_id,
        concept_id: concept_id,
        voided: 0
      ).where("LOWER(value_text) = ?", drug_name.downcase).exists?

      return if existing_observation

      encounter = Encounter.find(encounter_id)
      ObservationService.new.create_observation(encounter, {
        concept_id: concept_id,
        value_text: drug_name,
        obs_datetime: value_for(obs_payload, :obs_datetime) || value_for(order, :start_date),
        location_id: value_for(record, :location_id),
        order_id: order_id
      })
    end
  end
end
