# frozen_string_literal: true

# Performance patches for lab order serialization.
#
# Lab::OrdersSearchService.find_orders loads orders with
# Lab::LabOrder.prefetch_relationships, but Lab::LabOrderSerializer ignores
# the preloaded associations and re-queries each of them per order (each with
# a `concept_id IN (SELECT ... FROM concept_name ...)` subselect). For a
# patient with N historical orders that is ~20-30 queries per order, which is
# what makes saving/listing lab orders slow down as history grows.
#
# Three targeted fixes, all behavior-preserving:
# 1. serialize_order consumes the preloaded associations when present, but
#    falls through to the gem's own lookup when a preloaded association is
#    empty (so an empty :tests preload can never be persisted as `tests: []`).
# 2. concept_name (TEST CATALOGUE NAME attribute + concept name lookups) is
#    memoized per find_orders call via a thread-local cache.
# 3. latest_order_status/latest_test_status load the status trail association
#    once instead of querying `.last` and then the full trail separately.
module LabOrderSerializerPreloadedAssociations
  def serialize_order(order, tests: nil, requesting_clinician: nil, reason_for_test: nil, target_lab: nil, comment_to_fulfiller: nil)
    unless [1, true].include?(order.voided)
      # Only trust the preloaded :tests when it actually has rows. An empty
      # preloaded association (`[]`) is truthy, so assigning it here would
      # satisfy the gem's `tests ||= order_tests(order)` fallback and suppress
      # it — persisting `tests: []` into the patient record even when an
      # order-linked "Test type" observation exists. `.presence` turns `[]`
      # into nil so serialization falls through to the canonical `.unscoped`
      # re-query by order_id. (has_one associations below don't need this:
      # they return nil when absent, which is already falsy.)
      tests ||= preloaded_association(order, :tests).presence
                                                     &.sort_by { |test| [test.date_created || Time.at(0), test.obs_id || 0] }
    end
    requesting_clinician ||= preloaded_association(order, :requesting_clinician)
    reason_for_test ||= preloaded_association(order, :reason_for_test)
    target_lab ||= preloaded_association(order, :target_lab)
    comment_to_fulfiller ||= preloaded_association(order, :comment_to_fulfiller)

    super(order,
          tests: tests,
          requesting_clinician: requesting_clinician,
          reason_for_test: reason_for_test,
          target_lab: target_lab,
          comment_to_fulfiller: comment_to_fulfiller)
  end

  def concept_name(concept_id)
    cache = Thread.current[:lab_serializer_concept_name_cache]
    return super if cache.nil? || concept_id.nil?

    cache.key?(concept_id) ? cache[concept_id] : cache[concept_id] = super
  end

  def latest_order_status(order)
    # Load the trail once; `.last` and the subsequent trail serialization
    # then reuse the loaded association instead of issuing separate queries.
    order.status_trail_observations.load
    super
  end

  def latest_test_status(test)
    test.status_trail_observations.load
    super
  end

  private

  def preloaded_association(order, name)
    return nil unless order.respond_to?(:association)
    return nil unless order.association(name).loaded?

    order.public_send(name)
  end
end

# Scopes the concept-name memoization to a single find_orders call (concept
# names are immutable in practice, but keeping the cache request-scoped avoids
# any cross-request staleness).
module LabOrdersSearchServiceConceptNameCache
  def find_orders(filters)
    previous = Thread.current[:lab_serializer_concept_name_cache]
    Thread.current[:lab_serializer_concept_name_cache] = previous || {}
    super
  ensure
    Thread.current[:lab_serializer_concept_name_cache] = previous
  end
end

Rails.application.config.to_prepare do
  serializer = 'Lab::LabOrderSerializer'.safe_constantize
  if serializer
    singleton = serializer.singleton_class
    singleton.prepend(LabOrderSerializerPreloadedAssociations) unless singleton < LabOrderSerializerPreloadedAssociations
  end

  search_service = 'Lab::OrdersSearchService'.safe_constantize
  if search_service
    singleton = search_service.singleton_class
    singleton.prepend(LabOrdersSearchServiceConceptNameCache) unless singleton < LabOrdersSearchServiceConceptNameCache
  end
end
