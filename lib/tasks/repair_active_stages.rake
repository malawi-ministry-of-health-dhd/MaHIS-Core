# frozen_string_literal: true

# One-time repair for the "one active stage per program" invariant.
#
# A visit belongs to exactly one patient + program, so at most ONE active
# (status = true) stage may exist per open visit — and none once the visit is
# closed. Before the close_visit fix, stages were only retired when their
# location_id matched the closing context, so two classes of bad rows piled up:
#
#   * active-on-closed : status = true stage whose visit is already closed
#                        (date_stopped set) or missing. Online hides these via
#                        the visit join, but they are stale data and make offline
#                        over-count whenever the visit-close has not replicated.
#   * duplicate-active : more than one active stage on the SAME open visit. Only
#                        the most recently updated one is real; the rest are
#                        leftovers from a stage move that did not deactivate the
#                        prior row.
#
# The fix destroys the bad rows (and broadcasts a stage deletion so connected
# clients drop them), keeping the latest active stage on each still-open visit.
#
# Safe by default: DRY_RUN (report only). Set APPLY=1 to actually delete.
#   rails opd_queue:repair_active_stages          # report only
#   rails opd_queue:repair_active_stages APPLY=1  # delete bad rows
namespace :opd_queue do
  desc 'Enforce one active stage per program: retire active stages on closed visits and duplicate active stages'
  task repair_active_stages: :environment do
    apply = ENV['APPLY'] == '1'
    mode = apply ? 'APPLY (deleting)' : 'DRY RUN (report only — set APPLY=1 to delete)'
    puts "OPD active-stage repair — #{mode}"
    puts('-' * 64)

    stages_service = StagesService.new
    to_delete = []

    # ── active stages on a closed / missing visit ────────────────────────────
    Stage.where(status: true)
         .left_outer_joins(:visit)
         .where('visit.date_stopped IS NOT NULL OR visit.visit_id IS NULL')
         .find_each { |stage| to_delete << [stage, 'active-on-closed'] }

    # ── duplicate active stages on the same OPEN visit (keep the newest) ──────
    Stage.where(status: true)
         .joins(:visit)
         .where(visit: { date_stopped: nil })
         .group(:visit_id)
         .having('COUNT(*) > 1')
         .pluck(:visit_id)
         .each do |visit_id|
      dupes = Stage.where(visit_id: visit_id, status: true).order(updated_at: :desc).to_a
      dupes.drop(1).each { |stage| to_delete << [stage, 'duplicate-active'] }
    end

    if to_delete.empty?
      puts 'No bad rows found — invariant already holds.'
      puts('-' * 64)
      next
    end

    to_delete.each do |stage, reason|
      puts "  - stage #{stage.id} (#{reason}) visit=#{stage.visit_id} patient=#{stage.patient_id} " \
           "program=#{stage.program_id || 'NULL'} stage=#{stage.stage}"
      next unless apply

      stages_service.broadcast_stage_deletion(stage)
      stage.destroy
    end

    puts('-' * 64)
    if apply
      puts "Deleted #{to_delete.size} bad stage row(s)."
    else
      puts "DRY RUN complete — #{to_delete.size} row(s) would be deleted. Re-run with APPLY=1."
    end
  end
end
