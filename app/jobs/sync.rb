# frozen_string_literal: true

# Explicit declaration of the Sync namespace so Zeitwerk loads it as a real
# module (instead of an implicit, directory-derived one). Implicit namespaces
# work most of the time, but they can intermittently fail to resolve when a
# child class (e.g. `Sync::BulkPatientRecordSyncJob`) is referenced from a
# context that hasn't already triggered Zeitwerk on something inside the
# directory — notably Sidekiq workers booting in a fresh process and rake
# tasks that don't depend on :environment. Declaring the module here makes
# `Sync` resolvable on its own and removes that whole class of
# "uninitialized constant Sync" failures.
module Sync
end
