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
      voided_drug_orders = operation_value_for(record, :voidedDrugOders) || {}
      unsaved = operation_value_for(voided_drug_orders, :unsaved)
      return ok unless unsaved&.any?

      dispensation_service = DispensationService
      collected_errors = []
      processed_any = false

      unsaved.each do |entry|
        Array.wrap(operation_value_for(entry, :voidedDrugOders)).each do |void_obj|
          drug_order_id = operation_value_for(void_obj, :drug_order_id)
          next if drug_order_id.blank?

          begin
            reason = operation_value_for(void_obj, :reason).presence || 'Voided from patient record'

            result = with_operation_guard(
              patient_id: patient_id,
              operation_type: 'drug_order.void',
              payload: void_obj,
              target_type: 'DrugOrder'
            ) do
              void_drug_order!(drug_order_id, reason, dispensation_service)
              processed_any = true

              { target_type: 'DrugOrder', target_id: drug_order_id }
            end

            if result.skipped?
              void_drug_order!(drug_order_id, reason, dispensation_service)
              processed_any = true
              next
            end
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn("[VoidDrugOrders] DrugOrder #{drug_order_id} not found — skipping")
          rescue StandardError => e
            Rails.logger.error("[VoidDrugOrders] Error voiding DrugOrder #{drug_order_id}: #{e.message}")
            collected_errors << "DrugOrder #{drug_order_id}: #{e.message}"
          end
        end
      end

      OperationResult.new(success: true, errors: collected_errors, changed: processed_any)
    rescue StandardError => e
      log_and_fail("VoidDrugOrders#void_drug_orders", e)
    end

    private

    def void_drug_order!(drug_order_id, reason, dispensation_service)
      drug_order = DrugOrder.includes(:order).find(drug_order_id)
      return if drug_order.order&.voided?

      dispensation_service.void_dispensations(drug_order)
      drug_order.order&.void(reason)
    end
  end
end
