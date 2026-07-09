# frozen_string_literal: true

require 'rest-client'
require 'json'

# One-time repair for the OPD dashboard online-vs-offline count mismatch.
#
# Two classes of bad CouchDB docs accumulated before the doc-id fixes landed and
# do NOT self-heal (the sync jobs write under DIFFERENT ids, so they never
# overwrite these):
#
#   * stages : docs keyed by a bare identifier (e.g. "0YXPFG") or the legacy
#              "stage_<id>_<timestamp>" scheme. These collide across programs and
#              hide a patient's OPD stage behind their HTS stage.
#   * visits : more than one doc for the same visit_id (a stale "open" copy left
#              next to the authoritative "closed" copy), which makes offline
#              treat a closed visit as active and over-count its stage.
#
# Canonical schemes (already produced by StagesController / StageSyncJob and
# VisitsController / VisitSyncJob):
#   stages -> "<identifier>_<program_id>"      (ends with _<digits>)
#   visits -> "<identifier>_<date_started>"    (one per visit)
#
# This task DELETES the bad docs and then re-runs the (already-correct) sync jobs
# to rebuild canonical docs from the database (the source of truth).
#
# Safe by default: DRY_RUN (report only). Set APPLY=1 to actually delete.
#   rails opd_queue:repair_couchdb            # report only
#   rails opd_queue:repair_couchdb APPLY=1    # delete bad docs + enqueue re-sync
#   rails opd_queue:repair_couchdb APPLY=1 SKIP_RESYNC=1
namespace :opd_queue do
  desc 'Repair collided stage docs and duplicate visit docs behind the OPD dashboard count mismatch'
  task repair_couchdb: :environment do
    apply = ENV['APPLY'] == '1'
    skip_resync = ENV['SKIP_RESYNC'] == '1'
    # Defined here (not at parse time) so CouchdbSync from lib/ is autoloadable.
    repair = Class.new { include CouchdbSync }.new

    unless repair.couchdb_configured?
      puts 'CouchDB is not configured; nothing to repair.'
      next
    end

    mode = apply ? 'APPLY (deleting)' : 'DRY RUN (report only — set APPLY=1 to delete)'
    puts "OPD queue CouchDB repair — #{mode}"
    puts('-' * 64)

    fetch_docs = lambda do |db_name|
      response = RestClient.get("#{repair.couchdb_url(db_name)}/_all_docs?include_docs=true", accept: :json)
      JSON.parse(response.body).fetch('rows', [])
             .filter_map { |row| row['doc'] }
             .reject { |doc| doc['_id'].to_s.start_with?('_design/') }
    end

    delete_doc = lambda do |db_name, doc|
      return unless apply

      # Encode the id the same way sync_to_couchdb does when it writes docs.
      encoded_id = URI.encode_www_form_component(doc['_id'].to_s)
      RestClient.delete("#{repair.couchdb_url(db_name, encoded_id)}?rev=#{doc['_rev']}")
    end

    # ── stages: drop non-canonical (bare / legacy) ids ────────────────────────
    stage_docs = fetch_docs.call('stages')
    bad_stages = stage_docs.reject { |doc| doc['_id'].to_s.match?(/_\d+\z/) }
    puts "stages: #{stage_docs.size} docs, #{bad_stages.size} non-canonical (bare/legacy) to remove"
    bad_stages.each do |doc|
      puts "  - #{doc['_id']} (stage=#{doc['stage']} program=#{doc['program_id']})"
      delete_doc.call('stages', doc)
    end

    # ── visits: drop stale OPEN copies that have a CLOSED sibling ─────────────
    # A visit_id with both an open and a closed doc is unambiguous: the visit is
    # closed, so the open copy is stale and is what makes offline over-count the
    # queue. Deleting only these is safe and needs no DB lookup. Other kinds of
    # duplicates are left to the frontend open-visit guard + normal re-sync.
    visit_docs = fetch_docs.call('visits')
    by_visit_id = visit_docs.group_by { |doc| doc['visit_id'].to_s }

    removed_visits = 0
    stale_open_groups = by_visit_id.select do |visit_id, docs|
      visit_id.present? &&
        docs.any? { |doc| doc['date_stopped'].present? } &&
        docs.any? { |doc| doc['date_stopped'].blank? }
    end
    puts "visits: #{visit_docs.size} docs, #{stale_open_groups.size} visit_ids with a stale open+closed pair"
    stale_open_groups.each do |visit_id, docs|
      docs.select { |doc| doc['date_stopped'].blank? }.each do |doc|
        removed_visits += 1
        puts "  - visit #{visit_id}: drop stale open #{doc['_id']}"
        delete_doc.call('visits', doc)
      end
    end
    puts "  removed #{removed_visits} stale open visit docs"

    puts('-' * 64)
    if apply
      if skip_resync
        puts 'Deleted bad docs. Skipping re-sync (SKIP_RESYNC=1). Rebuild with:'
        puts '  rails "sync:run[StageSyncJob]" && rails "sync:run[VisitSyncJob]"'
      else
        Sync::StageSyncJob.perform_async
        Sync::VisitSyncJob.perform_async
        puts 'Deleted bad docs and enqueued StageSyncJob + VisitSyncJob to rebuild canonical docs.'
        puts '(Requires a running Sidekiq worker. Watch with: rails sync:progress)'
      end
    else
      puts 'DRY RUN complete — no changes made. Re-run with APPLY=1 to delete the docs above.'
    end
  end
end
