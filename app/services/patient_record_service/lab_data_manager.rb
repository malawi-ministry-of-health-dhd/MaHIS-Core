# app/services/patient_record_service/lab_data_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class LabDataManager < BaseSaver
    ENCOUNTER_TYPE_MAPPING = SavePatientRecordService::ENCOUNTER_TYPE_MAPPING

    def save_lab_orders_data(patient_id, record)
      save_lab_order(:labOrders, patient_id, record)
    end

    def save_lab_results_data(patient_id, record)
      save_lab_results(:labResults, patient_id, record)
    end

    def save_lab_order(data_type, patient_id, record)
      unsaved_data = record.dig(:labOrders, :unsaved)
      return false unless unsaved_data&.any?
      data_key = data_type.to_s.underscore.to_sym
      begin
        encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
        encounter_id = create_encounter(patient_id, encounter_type.id, record)
        orders = unsaved_data.map do |order_params|
          order_params = order_params.merge(encounter_id: encounter_id)
          Lab::OrdersService.order_test(order_params)
        end

        orders.each { |order| Lab::PushOrderJob.perform_later(order.fetch(:order_id)) }
        record[data_type][:unsaved] = []
        true
      rescue StandardError => e
        log_error("Failed to save #{data_type} information", e)
      end
    end

    def save_lab_results(data_type, patient_id, record)
      unsaved_data = record.dig(:labOrders, :results)
      return false unless unsaved_data&.any?
      data_key = data_type.to_s.underscore.to_sym

      begin
        encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
        encounter_id = create_encounter(patient_id, encounter_type.id, record)
        lab_results = unsaved_data[0].merge(encounter_id: encounter_id)
        Lab::ResultsService.create_results(lab_results[:test_id], lab_results)
        true
      rescue StandardError => e
        log_error("Failed to save #{data_type} information", e)
      end
    end

    def void_lab_order(_patient_id, record)
      data = record.dig(:labOrders, :voided)
      return false unless data&.any?
      data.map do |item|
        Lab::OrdersService.void_order(item[:orderId], item[:reason])
        Lab::VoidOrderJob.perform_later(item[:orderId])
      end
      record[:labOrders][:voided] = []
      true
    end
  end
end