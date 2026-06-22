# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'sidekiq/api'

# Terminal dashboard for the CouchDB sync. Renders two side-by-side columns —
# datasets on the left, live CouchDB index builds on the right — separated by a
# vertical divider, so the index section is never pushed off the bottom of a
# short terminal. On a real TTY it uses the alternate screen buffer and repaints
# a single fixed frame each tick (no scrolling, no repeated headers).
#
# Usage from a rake task:
#   SyncDashboard.new.watch
class SyncDashboard
  REFRESH_SECONDS = 0.5
  IDLE_EXIT_SECONDS = 120 # stop if nothing moves and no index is building
  STALL_WARN_SECONDS = 15 # warn (but keep watching) if work is queued yet nothing is processing it

  # Left (dataset) column geometry. Compact since each row is now a small dot
  # plus a percentage rather than a full-width bar.
  DS_NAME_WIDTH = 28
  DS_COUNT_WIDTH = 13
  LEFT_WIDTH = 62

  # Right (index) column geometry.
  IDX_NAME_WIDTH = 26
  IDX_BAR_WIDTH = 10

  # Queues the sync jobs run on. The watch must not finish until these drain,
  # otherwise slow-to-start jobs (patient fan-out, regimen engine) never register.
  SYNC_QUEUES = %w[sync_offline_data patient_sync batch_sync].freeze

  DIVIDER = ' │ '
  FILLED = '█'
  EMPTY  = '░'
  DOT    = '●'

  BOLD = "\e[1m"
  GREEN = "\e[32m"
  YELLOW = "\e[33m"
  RED = "\e[31m"
  RESET = "\e[0m"
  ANSI = /\e\[[0-9;]*m/.freeze

  STATUS_ORDER = { 'running' => 0, 'failed' => 1, 'done' => 2 }.freeze

  def initialize(output: $stdout, refresh: REFRESH_SECONDS, idle_exit: IDLE_EXIT_SECONDS)
    @output = output
    @refresh = refresh
    @idle_exit = idle_exit
    @cursor = TTY::Cursor
    @tty = @output.respond_to?(:tty?) ? @output.tty? : false
    @seen_tables = false
    @entered = false
    @last_fingerprint = nil
    @last_change_at = monotonic
    @started_at = monotonic
  end

  def watch
    enter_screen
    loop do
      paint(frame)
      break if finished? || idle_timed_out?

      sleep(@refresh)
    end
  rescue Interrupt
    @interrupted = true
  ensure
    leave_screen
    # The alternate screen buffer is discarded on exit, so reprint the full
    # final frame (height-unclamped) to the normal screen — the stats stay
    # visible after the watch ends instead of being cleared.
    @output.puts(frame(limit_height: false).join("\n")) if @tty
    print_summary
  end

  private

  # ---- data ----------------------------------------------------------------

  def datasets
    rows = SyncProgress.snapshot
    @seen_tables = true if rows.any?
    rows.sort_by { |r| [STATUS_ORDER.fetch(r[:status], 9), r[:type].to_s] }
  end

  def index_tasks
    CouchdbIndexProgress.active
  rescue StandardError
    []
  end

  # ---- frame composition ---------------------------------------------------

  def frame(limit_height: true)
    rows = datasets
    tasks = index_tasks
    track_activity(rows, tasks)

    lines = [header(rows)]
    lines.concat(warning_lines)
    lines << ''
    lines.concat(zip_columns(dataset_block(rows), index_block(tasks)))
    lines = clamp_width(lines)
    limit_height ? clamp_height(lines) : lines
  end

  # A banner shown when a sync should be progressing but isn't — the usual cause
  # of a dashboard stuck at "0/0 … waiting for sync jobs to start". Distinguishes
  # the failure modes so the fix is obvious.
  def warning_lines
    return [] unless stalled?

    if !sidekiq_running?
      [warn_text('⚠ No Sidekiq worker detected — queued jobs will not run. Start one with:'),
       warn_text('    bundle exec sidekiq -C config/sidekiq.yml')]
    elsif busy_sync_workers?
      [warn_text('⚠ A sync job has been running with no progress — it may be stuck (often'),
       warn_text('    CouchDB unreachable). Check `rails sync:doctor` and the Sidekiq log.')]
    elsif sync_jobs_pending?
      [warn_text('⚠ Jobs are queued but no worker is processing them — is Sidekiq listening to'),
       warn_text('    batch_sync, patient_sync, sync_offline_data?   Run `rails sync:doctor`.')]
    elsif !@seen_tables
      [warn_text('⚠ Nothing is queued or running and nothing has synced — enqueues may have been'),
       warn_text('    dropped (stale locks). Run `rails sync:doctor`, then `rails sync:clear_locks`.')]
    else
      [warn_text('⚠ A dataset is still marked “syncing” but no worker is processing it — the job'),
       warn_text('    likely ended without reporting completion. Re-run or check `rails sync:doctor`.')]
    end
  end

  def header(rows)
    done = rows.count { |r| r[:status] == 'done' }
    failed = rows.count { |r| r[:status] == 'failed' }
    parts = ["#{done}/#{rows.size} done"]
    parts << "#{failed} failed" if failed.positive?
    bold('MaHIS CouchDB sync') + "  #{parts.join('  ·  ')}  ·  elapsed #{elapsed}"
  end

  def dataset_block(rows)
    lines = ['DATASETS', '']
    if rows.empty?
      lines << '  (waiting for sync jobs to start…)'
    else
      # One line per dataset (no blank spacer): with ~30 datasets the spacer
      # doubled the height and pushed the still-running rows off the top of the
      # terminal in the final repaint.
      rows.each { |r| lines << dataset_line(r) }
    end
    lines
  end

  def index_block(tasks)
    lines = ['INDEX BUILDS', '']
    if tasks.empty?
      lines << '  (none building)'
    else
      tasks.sort_by(&:label).each { |t| lines << index_line(t) }
    end
    lines
  end

  # Merge the two columns row-by-row with a vertical divider down the middle.
  def zip_columns(left, right)
    rows = [left.size, right.size].max
    (0...rows).map do |i|
      l = ljust_visible(left[i] || '', LEFT_WIDTH)
      "#{l}#{DIVIDER}#{right[i]}".rstrip
    end
  end

  def dataset_line(row)
    total = row[:total].to_i
    done = [row[:done].to_i, 0].max
    ratio = total.positive? ? [done.to_f / total, 1.0].min : (row[:status] == 'done' ? 1.0 : 0.0)
    status = row[:status] == 'running' ? 'syncing' : row[:status]
    counts = "#{done}/#{total}"
    "  #{status_dot(row[:status])} #{cell(row[:type], DS_NAME_WIDTH)} #{pct(ratio)}  #{counts.ljust(DS_COUNT_WIDTH)} #{status}"
  end

  # Compact status indicator: a small coloured dot instead of a full progress bar
  # (green = done, yellow = syncing, red = failed). The percentage still conveys
  # partial progress for in-flight datasets.
  def status_dot(status)
    return DOT unless @tty

    color = case status
            when 'done' then GREEN
            when 'failed' then RED
            else YELLOW
            end
    "#{color}#{DOT}#{RESET}"
  end

  def index_line(task)
    ratio = task.progress.to_i.clamp(0, 100) / 100.0
    detail = task.total_changes.positive? ? "#{task.changes_done}/#{task.total_changes}" : 'building'
    "  #{cell(index_name(task), IDX_NAME_WIDTH)} #{bar(ratio, IDX_BAR_WIDTH)} #{pct(ratio)}  #{detail}"
  end

  # ---- rendering primitives ------------------------------------------------

  def bar(ratio, width)
    filled = (ratio * width).round.clamp(0, width)
    fill = FILLED * filled
    rest = EMPTY * (width - filled)
    @tty ? "#{GREEN}#{fill}#{RESET}#{rest}" : (fill + rest)
  end

  # ANSI-aware helpers so the green bar codes don't throw off column alignment.
  def visible_length(str)
    str.gsub(ANSI, '').length
  end

  def ljust_visible(str, width)
    pad = width - visible_length(str)
    pad.positive? ? str + (' ' * pad) : str
  end

  def pct(ratio)
    "#{(ratio * 100).round.to_s.rjust(3)}%"
  end

  def cell(text, width)
    truncate(text.to_s, width).ljust(width)
  end

  # Patient indexes all share the patients_records db; show just the ddoc name.
  def index_name(task)
    ddoc = task.design_document.to_s.sub(%r{\A_design/}, '')
    ddoc.empty? ? task.label : ddoc
  end

  def truncate(text, width)
    text.length <= width ? text : "#{text[0, width - 1]}…"
  end

  def bold(text)
    @tty ? "#{BOLD}#{text}#{RESET}" : text
  end

  def warn_text(text)
    @tty ? "#{YELLOW}#{text}#{RESET}" : text
  end

  # ---- screen control ------------------------------------------------------

  def enter_screen
    return unless @tty
    return if @entered

    @output.print("\e[?1049h") # switch to alternate screen buffer
    @output.print(@cursor.hide)
    @output.print("\e[H\e[2J")  # home + clear
    @entered = true
  end

  def leave_screen
    return unless @entered

    @output.print(@cursor.show)
    @output.print("\e[?1049l") # restore primary screen buffer
    @entered = false
  end

  def paint(lines)
    if @tty
      buffer = +"\e[H" # home
      lines.each { |line| buffer << line << "\e[K\n" } # line + clear-to-EOL
      buffer << "\e[J" # clear everything below
      @output.print(buffer)
    else
      @output.puts(lines.join("\n"))
      @output.puts
    end
    @output.flush
  end

  # Truncate each row to terminal width so a narrow terminal can't wrap a row
  # (which would break the fixed in-place repaint). Measure by visible length;
  # on overflow drop ANSI and hard-cut so no color bleeds past the edge.
  def clamp_width(lines)
    width = screen_width
    return lines unless width.positive?

    lines.map do |line|
      visible_length(line) > width ? "#{line.gsub(ANSI, '')[0, width]}#{RESET}" : line
    end
  end

  def clamp_height(lines)
    max = screen_height - 1
    return lines if max <= 0 || lines.size <= max

    kept = lines.first(max - 1)
    kept << "  … #{lines.size - kept.size} more (terminal too short)"
    kept
  end

  def screen_height
    TTY::Screen.height
  rescue StandardError
    40
  end

  def screen_width
    TTY::Screen.width
  rescue StandardError
    160
  end

  # ---- lifecycle -----------------------------------------------------------

  def track_activity(rows, tasks)
    fingerprint = [
      rows.map { |r| [r[:type], r[:done], r[:status]] },
      tasks.map { |t| [t.label, t.progress] }
    ]
    return if fingerprint == @last_fingerprint

    @last_fingerprint = fingerprint
    @last_change_at = monotonic
  end

  def finished?
    @seen_tables && !sync_jobs_pending? && SyncProgress.all_finished? && CouchdbIndexProgress.idle?
  end

  # Any sync jobs still queued, scheduled, retrying, or running? Keeps the watch
  # alive until every enqueued job has registered and completed.
  def sync_jobs_pending?
    return true if SYNC_QUEUES.any? { |q| Sidekiq::Queue.new(q).size.positive? }
    return true if sync_jobs_in_set?(Sidekiq::ScheduledSet.new)
    return true if sync_jobs_in_set?(Sidekiq::RetrySet.new)

    busy_sync_workers?
  rescue StandardError
    false # never block exit on an introspection failure
  end

  def sync_jobs_in_set?(set)
    set.any? { |job| SYNC_QUEUES.include?(job.queue) }
  end

  def busy_sync_workers?
    Sidekiq::Workers.new.any? { |_process, _thread, work| SYNC_QUEUES.include?(work.queue) }
  rescue StandardError
    false
  end

  def idle_timed_out?
    # Keep watching while CouchDB is indexing or a sync worker is actively running
    # a job (a long patient fan-out can go a while between progress ticks). Only
    # give up after a sustained quiet period. Crucially this still exits when
    # Sidekiq is down or not consuming the sync queues — jobs queued with no busy
    # worker — instead of hanging forever on "waiting for sync jobs to start".
    return false unless CouchdbIndexProgress.idle?
    return false if busy_sync_workers?

    (monotonic - @last_change_at) > @idle_exit
  end

  # True when a sync should be moving but hasn't for a sustained period — drives
  # the on-screen warning. Fires when, after the grace period and with no index
  # building, there has been no progress AND either nothing is processing the
  # work, a worker is stuck (busy but never registered any dataset), or nothing
  # ever registered at all.
  def stalled?
    return false if (monotonic - @started_at) < STALL_WARN_SECONDS
    return false unless CouchdbIndexProgress.idle?
    # Once any dataset has completed, the sync is clearly working — don't flash a
    # warning during the normal finalize tail (the patient index-build poller is
    # "scheduled", which otherwise looks like queued-but-unprocessed work). The
    # end-of-run summary reports any stragglers instead.
    return false if any_completed?
    return false unless (monotonic - @last_change_at) > STALL_WARN_SECONDS

    !busy_sync_workers? || !@seen_tables
  end

  def any_completed?
    SyncProgress.snapshot.any? { |row| %w[done failed].include?(row[:status]) }
  end

  def sidekiq_running?
    Sidekiq::ProcessSet.new.size.positive?
  rescue StandardError
    false
  end

  def print_summary
    rows = SyncProgress.snapshot
    done = rows.count { |r| r[:status] == 'done' }
    failed = rows.select { |r| r[:status] == 'failed' }
    unfinished = rows.reject { |r| %w[done failed].include?(r[:status]) }
                     .sort_by { |r| r[:type].to_s }
    @output.puts
    @output.puts 'Progress watch interrupted (sync continues in the background).' if @interrupted
    @output.puts bold("Sync state: #{done}/#{rows.size} datasets done.")
    failed.each { |r| @output.puts "  failed   #{r[:type]}: #{r[:message]}" }
    # Always name the still-running datasets explicitly — they sort to the top of
    # the live frame and can scroll off, so this is the reliable place to see them.
    unless unfinished.empty?
      @output.puts "  still syncing (#{unfinished.size}):"
      unfinished.each { |r| @output.puts "    #{r[:type].to_s.ljust(DS_NAME_WIDTH)} #{r[:done]}/#{r[:total]} (#{r[:status]})" }
    end
    @output.puts '  (timed out waiting for activity — sync may still be running)' if idle_timed_out? && !finished?

    # If nothing ran, the most likely cause is no worker — say so explicitly.
    if rows.empty? || (sync_jobs_pending? && !sidekiq_running?)
      @output.puts
      @output.puts warn_text('No Sidekiq worker is processing the sync queues.')
      @output.puts '  Start one in another terminal:  bundle exec sidekiq -C config/sidekiq.yml'
    end
  end

  def elapsed
    secs = (monotonic - @started_at).to_i
    secs < 60 ? "#{secs}s" : "#{secs / 60}m#{(secs % 60).to_s.rjust(2, '0')}s"
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
