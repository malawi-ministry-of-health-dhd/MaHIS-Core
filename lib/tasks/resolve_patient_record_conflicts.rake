# frozen_string_literal: true

# Server-side, merge-aware resolution of CouchDB `patients_records` conflicts.
#
# Conflicts are inherent to offline-first replication (same doc `_id` edited on a
# replica and on the server). CouchDB keeps a structural winner plus the losing
# branches as `_conflicts`; today only the frontend resolves them, and only when
# a user opens the sync-badge UI, so conflicts pile up. This task collapses each
# conflicted doc to a single revision using PatientRecordConflictResolver:
# the winner (latest by timestamp, then generation) supplies the base content,
# and every clinical record (observation, order, identifier, ...) that exists
# only in a losing branch is merged in first, so nothing clinical is dropped.
#
# Safe by default: DRY RUN (report only). Set APPLY=1 to write.
#   rails patient_records:resolve_conflicts              # sweep, report only
#   rails patient_records:resolve_conflicts APPLY=1      # sweep + resolve
#   rails patient_records:resolve_conflicts ID=0UXTE7    # one doc, report only
#   rails patient_records:resolve_conflicts ID=0UXTE7 APPLY=1
namespace :patient_records do
  desc 'Resolve CouchDB patient_records conflicts (merge-aware). DRY RUN unless APPLY=1.'
  task resolve_conflicts: :environment do
    apply = ENV['APPLY'] == '1'
    single_id = ENV['ID'].presence

    resolver = PatientRecordConflictResolver.new(dry_run: !apply)
    unless resolver.couchdb_configured?
      puts 'CouchDB is not configured; nothing to do.'
      next
    end

    mode = apply ? 'APPLY (writing merged docs + deleting losing revisions)' : 'DRY RUN (report only — set APPLY=1 to resolve)'
    puts "Patient record conflict resolver — #{mode}"
    puts('-' * 72)

    report = lambda do |result|
      merged = result.additions.reject { |_, count| count.zero? }
                     .map { |name, count| "#{name}+#{count}" }.join(', ')
      base_note = result.winner_src_rev == result.winner_rev ? '' : " (content from #{result.winner_src_rev})"
      puts "  #{result.id}  winner=#{result.winner_rev}#{base_note}  losers=#{result.loser_revs.size}  " \
           "merged=[#{merged.presence || 'none'}]"
    end

    total = 0
    total_additions = 0

    if single_id
      result = resolver.resolve(single_id)
      if result.nil?
        puts "  #{single_id}: document not found."
      elsif !result.conflicted?
        puts "  #{single_id}: no conflicts."
      else
        report.call(result)
        total = 1
        total_additions = result.total_additions
      end
    else
      resolver.sweep do |result|
        total += 1
        total_additions += result.total_additions
        report.call(result)
      end
    end

    puts('-' * 72)
    puts "#{total} conflicted document(s); #{total_additions} clinical record(s) " \
         "#{apply ? 'merged' : 'would be merged'} from losing revisions."
    puts(apply ? 'Applied — losing revisions tombstoned.' : 'DRY RUN — no changes made. Re-run with APPLY=1 to resolve.')
  end
end
