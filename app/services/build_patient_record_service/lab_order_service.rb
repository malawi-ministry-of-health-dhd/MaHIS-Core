# frozen_string_literal: true
module BuildPatientRecordService
  module LabOrderService
    def safe_get_lab_orders(patient_id)
      begin
        return [] unless patient_id
        Lab::OrdersSearchService.find_orders(patient_id: patient_id)
      rescue StandardError => e
        Rails.logger.error("Error getting lab orders for patient #{patient_id}: #{e.message}")
        []
      end
    end
  end
end