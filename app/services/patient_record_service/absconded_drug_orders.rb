# app/services/patient_record_service/absconded_drug_orders.rb
# frozen_string_literal: true

module PatientRecordService
  class AbscondedDrugOrders < BaseSaver
    # Process abscondments queued by the frontend (offline or online).
    #
    # The frontend stores pending abscondments in:
    #   record[:abscondedDrugOrders][:unsaved][]
    #     .abscondedDrugOrders[] => [{ drug_order_id:, date:, reason: }]
    #
    # Shape and key nesting deliberately mirror OutOfStockDrugOrders so both
    # queues are processed and cleared the same way. A pending container is
    # required rather than a flag on MedicationOrder.saved[]: that list is rebuilt
    # from MySQL on every medication operation, so it cannot carry pending intent.
    def mark_absconded(patient_id, record)
      absconded_orders = operation_value_for(record, :abscondedDrugOrders) || {}
      unsaved = operation_value_for(absconded_orders, :unsaved)
      return ok unless unsaved&.any?

      collected_errors = []
      processed_any = false

      unsaved.each do |entry|
        Array.wrap(operation_value_for(entry, :abscondedDrugOrders)).each do |abscond|
          drug_order_id = operation_value_for(abscond, :drug_order_id)
          next if drug_order_id.blank?

          begin
            reason = operation_value_for(abscond, :reason).presence || 'Patient absconded'

            result = with_operation_guard(
              patient_id: patient_id,
              operation_type: 'drug_order.absconded',
              payload: abscond,
              target_type: 'DrugOrder'
            ) do
              mark_drug_order_absconded!(drug_order_id, reason)
              processed_any = true

              { target_type: 'DrugOrder', target_id: drug_order_id }
            end

            if result.skipped?
              mark_drug_order_absconded!(drug_order_id, reason)
              processed_any = true
              next
            end
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn("[AbscondedDrugOrders] DrugOrder #{drug_order_id} not found — skipping")
          rescue StandardError => e
            Rails.logger.error("[AbscondedDrugOrders] Error marking DrugOrder #{drug_order_id} absconded: #{e.message}")
            collected_errors << "DrugOrder #{drug_order_id}: #{e.message}"
          end
        end
      end

      OperationResult.new(success: true, errors: collected_errors, changed: processed_any)
    rescue StandardError => e
      log_and_fail('AbscondedDrugOrders#mark_absconded', e)
    end

    private

    def mark_drug_order_absconded!(drug_order_id, reason)
      drug_order = DrugOrder.includes(:order).find(drug_order_id)
      # A voided order has already left the queue; do not relabel it.
      return if drug_order.order&.voided?

      DispensationService.mark_absconded(drug_order, reason: reason)
    end
  end
end
