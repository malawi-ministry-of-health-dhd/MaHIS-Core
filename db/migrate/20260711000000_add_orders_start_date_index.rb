# frozen_string_literal: true

# Speeds up the "awaiting dispensation" queue, which now scans only orders whose
# start_date falls in a recent window (see
# DrugOrderService::DISPENSATION_QUEUE_WINDOW_DAYS). No existing index leads with
# start_date, so the window filter could not drive the scan and MySQL fell back
# to scanning the whole drug_order/orders join. This index lets the date range
# drive the query; the trailing order_id keeps the join to drug_order/encounter
# an index-only lookup.
class AddOrdersStartDateIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :orders, %i[start_date order_id],
              name: 'idx_orders_start_date_order',
              if_not_exists: true
  end
end
