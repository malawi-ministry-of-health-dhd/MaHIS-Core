# app/services/patient_record_service/void_drug_orders.rb
# frozen_string_literal: true

module PatientRecordService
  class VoidDrugOrders < BaseSaver
    # Process voided drug order entries queued by the frontend while offline.
    #
    # The frontend stores pending voids in:
    #   record[:voidedDrugOders][:unsaved][]
    #     .voidedDrugOders[] => [{ drug_order_id:, date:, reason: }]
    #
    # Note: the key `voidedDrugOders` is intentionally misspelled to match
    # the frontend convention established by the NCD module.
    def void_drug_orders(patient_id, record)
      unsaved = record.dig(:voidedDrugOders, :unsaved)
      return ok unless unsaved&.any?

      dispensation_service = DispensationService.new
      collected_errors = []

      unsaved.each do |entry|
        Array.wrap(entry[:voidedDrugOders]).each do |void_obj|
          drug_order_id = void_obj[:drug_order_id]
          next if drug_order_id.blank?

          begin
            result = with_operation_guard(
              patient_id: patient_id,
              operation_type: 'drug_order.void',
              payload: void_obj,
              target_type: 'DrugOrder'
            ) do
              drug_order = DrugOrder.find(drug_order_id)
              dispensation_service.void_dispensations(drug_order)
              { target_type: 'DrugOrder', target_id: drug_order_id }
            end

            next if result.skipped?
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn("[VoidDrugOrders] DrugOrder #{drug_order_id} not found — skipping")
          rescue StandardError => e
            Rails.logger.error("[VoidDrugOrders] Error voiding DrugOrder #{drug_order_id}: #{e.message}")
            collected_errors << "DrugOrder #{drug_order_id}: #{e.message}"
          end
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("VoidDrugOrders#void_drug_orders", e)
    end
  end
end
