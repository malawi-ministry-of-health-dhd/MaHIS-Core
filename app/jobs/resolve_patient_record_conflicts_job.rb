# frozen_string_literal: true

# Periodic safety-net sweep that resolves accumulated CouchDB patients_records
# conflicts server-side, merge-aware (see PatientRecordConflictResolver).
#
# The listener resolves conflicts on each doc it processes inline; this job
# catches conflicts on docs that no writer touches again (e.g. two offline
# devices that both went quiet). Scheduled via config/schedule.yml (sidekiq-cron).
class ResolvePatientRecordConflictsJob < ApplicationJob
  queue_as :default

  def perform(page_size = 500)
    resolver = PatientRecordConflictResolver.new(dry_run: false)
    return unless resolver.couchdb_configured?

    resolved = 0
    merged = 0
    resolver.sweep(page_size: page_size) do |result|
      resolved += 1
      merged += result.total_additions
    end

    return unless resolved.positive?

    Rails.logger.info(
      "[ConflictSweep] Resolved #{resolved} patients_records conflict(s); " \
      "merged #{merged} clinical record(s) from losing revisions."
    )
  end
end
