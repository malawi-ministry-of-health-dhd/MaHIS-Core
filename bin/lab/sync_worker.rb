# frozen_string_literal: true

Test::Unit::AutoRunner.need_auto_run = false if defined?(Test::Unit::AutoRunner)

minimum_date = Date.parse('2026-01-01')
# To avoid processing an excessive amount of historical data, we limit the start date to 120 days ago or the minimum date, whichever is later.
# 120 days because that's approximately 4 months, which is a reasonable window for syncing vl results that have taken long to process in the lab and may not have been synced yet.
sixty_days_ago = Date.today - 1.days
start_date = [sixty_days_ago, minimum_date].max.to_s

def start_lims_sync_workers(start_date:)
  User.current = Lab::Lims::Utils.lab_user

  # In development Rails starts rb-fsevent child processes for file watching.
  # Lab::Lims::Worker.start uses Process.waitall, which waits for those watcher
  # children too and keeps this one-shot cron runner alive forever.
  Rails.application.eager_load! if defined?(Rails) && Rails.env.development?

  worker_pids = [
    fork { Lab::Lims::Worker.start_push_worker(start_date: start_date) },
    fork { Lab::Lims::Worker.start_pull_worker(start_date: start_date) },
    fork { Lab::Lims::Worker.start_acknowledgement_worker(start_date: start_date) }
  ]

  if Lab::Lims::Worker.realtime_updates_enabled?
    worker_pids << fork { Lab::Lims::Worker.start_realtime_pull_worker(start_date: start_date) }
  end

  failed_workers = worker_pids.filter_map do |pid|
    _finished_pid, status = Process.wait2(pid)
    next if status.success?

    [pid, status.exitstatus || status.termsig]
  rescue Errno::ECHILD
    nil
  end

  return if failed_workers.empty?

  Rails.logger.error("LIMS sync worker failures: #{failed_workers.inspect}")
  exit 1
end

start_lims_sync_workers(start_date: start_date)
