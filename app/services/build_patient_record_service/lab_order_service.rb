# frozen_string_literal: true
module BuildPatientRecordService
  module LabOrderService
    def safe_get_lab_orders(patient_id)
      begin
        return [] unless patient_id
        orders = Lab::OrdersSearchService.find_orders(patient_id: patient_id)
        attach_order_created_dates(orders)
      rescue StandardError => e
        Rails.logger.error("Error getting lab orders for patient #{patient_id}: #{e.message}")
        []
      end
    end

    # The lab gem serialises orders with midnight timestamps (order_date /
    # order_status), so the offline dashboard has no real time to compute a
    # waiting time from. Attach the order's actual date_created (wall-clock
    # creation time) — matching what the online dashboard uses (see
    # HtsService::Dashboard#find_orders `waiting_since`).
    def attach_order_created_dates(orders)
      return orders unless orders.is_a?(Array) && orders.any?

      order_ids = orders.map { |order| order[:order_id] || order['order_id'] }.compact
      return orders if order_ids.empty?

      created_at = Order.where(order_id: order_ids).pluck(:order_id, :date_created).to_h
      orders.each do |order|
        timestamp = created_at[order[:order_id] || order['order_id']]
        next unless timestamp

        order[order.key?(:order_id) ? :date_created : 'date_created'] = timestamp
      end
      orders
    end
  end
end