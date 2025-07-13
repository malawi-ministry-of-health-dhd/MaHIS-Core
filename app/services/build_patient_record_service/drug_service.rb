# frozen_string_literal: true
module BuildPatientRecordService
 module DrugService
    def get_client_drug_orders(patient_id)
      begin
        return [] if patient_id.nil? || patient_id.to_s.strip.empty?
        return DrugOrderService.fetch_all_patient_drug_orders(patient_id)
      rescue => e
        Rails.logger.error("Outer error fetching drug orders for patient #{patient_id}: #{e.message}")
        []
      end
    end
  end
end
