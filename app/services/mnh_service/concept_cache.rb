# frozen_string_literal: true

module MnhService
  # Process-wide cache of concept_name => concept_id lookups.
  #
  # The MNH stats queries resolve the same concept names for every facility.
  # Memoizing only per query-instance (one instance per facility) meant the
  # same `ConceptName.find_by(name:)` ran thousands of times during a fan-out
  # run. Concept metadata is effectively static at runtime, so a shared cache
  # is safe and removes the redundant lookups. Misses are cached too so absent
  # concepts are not re-queried on every facility.
  module ConceptCache
    MISSING = :__concept_missing__
    CACHE = Concurrent::Map.new

    module_function

    def concept_id(name)
      key = name.to_s
      return nil if key.empty?

      value = CACHE.compute_if_absent(key) do
        ConceptName.unscoped.find_by(name: name)&.concept_id || MISSING
      end
      value == MISSING ? nil : value
    end

    def reset!
      CACHE.clear
    end
  end
end
