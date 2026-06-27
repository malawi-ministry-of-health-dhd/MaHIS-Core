# frozen_string_literal: true

module MnhService
  # Process-wide cache of concept_name => concept_id lookups.
  #
  # The MNH stats queries resolve the same concept names for every facility.
  # Memoizing only per query-instance (one instance per facility) meant the
  # same `ConceptName.find_by(name:)` ran thousands of times during a fan-out
  # run. Concept metadata is effectively static at runtime, so a shared cache
  # is safe and removes the redundant lookups.
  #
  # IMPORTANT: only HITS are cached. Caching a miss permanently (process-wide,
  # no TTL) is dangerous — if a long-lived worker ever resolves a concept to nil
  # once (cold start before metadata is loaded, replication lag, a transient
  # error), every later stats computation in that worker would silently return 0
  # for the affected metric. Re-querying the rare genuine miss is cheap and safe.
  module ConceptCache
    CACHE = Concurrent::Map.new

    module_function

    def concept_id(name)
      key = name.to_s
      return nil if key.empty?

      cached = CACHE[key]
      return cached unless cached.nil?

      id = ConceptName.unscoped.find_by(name: name)&.concept_id
      CACHE[key] = id unless id.nil?
      id
    end

    def reset!
      CACHE.clear
    end
  end
end
