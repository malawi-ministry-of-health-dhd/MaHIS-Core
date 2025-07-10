# app/services/patient_record_service/medication_order_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class MedicationOrderSaver < BaseSaver
    ENCOUNTER_TYPE_MAPPING = SavePatientRecordService::ENCOUNTER_TYPE_MAPPING

    def save_medication_order(patient_id, record)
      orders = record.dig(:MedicationOrder, :unsaved)
      return unless orders&.any?

      begin
        ActiveRecord::Base.transaction do
          orders.each do |order|
            next unless order.key?(:NCD_Drug_Orders)
            drug_orders = order[:NCD_Drug_Orders]
            encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:treatment])
            encounter_id = create_encounter(patient_id, encounter_type.id, record)
            encounter = Encounter.find(encounter_id)

            unless encounter.type.name == 'TREATMENT'
              Rails.logger.warn("Unexpected encounter type: #{encounter.type.name} for encounter ##{encounter.encounter_id}")
              next
            end

            DrugOrderService.create_drug_orders(encounter: encounter, drug_orders: drug_orders)
          end
        end
      rescue StandardError => e
        log_error("Failed to create medication order", e)
        raise # Re-raise if you want the transaction to rollback
      end
    end
  end
end