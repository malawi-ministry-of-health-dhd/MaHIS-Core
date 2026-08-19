# app/services/patient_record_service/out_of_stock_drug_orders.rb
# frozen_string_literal: true

module PatientRecordService
  class OutOfStockDrugOrders < BaseSaver
    # Process stock-outs queued by the frontend (offline or online).
    #
    # The frontend stores pending stock-outs in:
    #   record[:outOfStockDrugOrders][:unsaved][]
    #     .outOfStockDrugOrders[] => [{ drug_order_id:, date:, reason: }]
    #
    # Shape and key nesting deliberately mirror VoidDrugOrders / voidedDrugOders so
    # both queues are processed and cleared the same way. A pending container is
    # required rather than a flag on MedicationOrder.saved[]: that list is rebuilt
    # from MySQL on every medication operation, so it cannot carry pending intent.
    def mark_out_of_stock(patient_id, record)
      out_of_stock_orders = operation_value_for(record, :outOfStockDrugOrders) || {}
      unsaved = operation_value_for(out_of_stock_orders, :unsaved)
      return ok unless unsaved&.any?

      collected_errors = []
      processed_any = false

      unsaved.each do |entry|
        Array.wrap(operation_value_for(entry, :outOfStockDrugOrders)).each do |stock_out|
          drug_order_id = operation_value_for(stock_out, :drug_order_id)
          next if drug_order_id.blank?

          begin
            reason = operation_value_for(stock_out, :reason).presence || 'Out of stock'

            result = with_operation_guard(
              patient_id: patient_id,
              operation_type: 'drug_order.out_of_stock',
              payload: stock_out,
              target_type: 'DrugOrder'
            ) do
              mark_drug_order_out_of_stock!(drug_order_id, reason)
              processed_any = true

              { target_type: 'DrugOrder', target_id: drug_order_id }
            end

            if result.skipped?
              mark_drug_order_out_of_stock!(drug_order_id, reason)
              processed_any = true
              next
            end
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn("[OutOfStockDrugOrders] DrugOrder #{drug_order_id} not found — skipping")
          rescue StandardError => e
            Rails.logger.error("[OutOfStockDrugOrders] Error marking DrugOrder #{drug_order_id} out of stock: #{e.message}")
            collected_errors << "DrugOrder #{drug_order_id}: #{e.message}"
          end
        end
      end

      OperationResult.new(success: true, errors: collected_errors, changed: processed_any)
    rescue StandardError => e
      log_and_fail('OutOfStockDrugOrders#mark_out_of_stock', e)
    end

    private

    def mark_drug_order_out_of_stock!(drug_order_id, reason)
      drug_order = DrugOrder.includes(:order).find(drug_order_id)
      # A voided order has already left the queue; do not relabel it.
      return if drug_order.order&.voided?

      DispensationService.mark_out_of_stock(drug_order, reason: reason)
    end
  end
end
