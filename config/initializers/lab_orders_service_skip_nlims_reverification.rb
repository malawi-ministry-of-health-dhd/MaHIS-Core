# frozen_string_literal: true

# Skip the synchronous NLIMS accession-number re-verification inside
# Lab::OrdersService.order_test.
#
# When an order arrives with an accession number, order_test calls
# check_tracking_number, whose NLIMS half is a blocking HTTP call (plus an
# auth handshake) made inside the Order.transaction. The frontend has already
# verified the accession number against NLIMS at barcode-scan time (or the
# user explicitly confirmed when NLIMS was unreachable), so re-verifying here
# only adds external-service latency to every save. NLIMS itself still
# rejects duplicate tracking numbers when the order is pushed.
#
# The local duplicate check (accession_number_exists?) still runs, and the
# scan-time verification endpoint (OrdersController#verify_tracking_number)
# is unaffected because it calls check_tracking_number outside order_test.
module LabOrdersServiceSkipNlimsReverification
  def order_test(order_params)
    previous = Thread.current[:skip_nlims_accession_reverification]
    Thread.current[:skip_nlims_accession_reverification] = true
    super
  ensure
    Thread.current[:skip_nlims_accession_reverification] = previous
  end

  def nlims_accession_number_exists?(accession_number)
    return false if Thread.current[:skip_nlims_accession_reverification]

    super
  end
end

Rails.application.config.to_prepare do
  service = 'Lab::OrdersService'.safe_constantize
  next unless service

  singleton = service.singleton_class
  singleton.prepend(LabOrdersServiceSkipNlimsReverification) unless singleton < LabOrdersServiceSkipNlimsReverification
end
