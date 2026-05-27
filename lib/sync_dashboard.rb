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

  # Left (dataset) column geometry.
  DS_NAME_WIDTH = 28
  DS_BAR_WIDTH = 12
  DS_COUNT_WIDTH = 13
  LEFT_WIDTH = 90

  # Right (index) column geometry.
  IDX_NAME_WIDTH = 26
  IDX_BAR_WIDTH = 10

  # Queues the sync jobs run on. The watch must not finish until these drain,
  # otherwise slow-to-start jobs (patient fan-out, regimen engine) never register.
  SYNC_QUEUES = %w[sync_offline_data patient_sync batch_sync].freeze

  DIVIDER = ' │ '
  FILLED = '█'
  EMPTY  = '░'

  BOLD = "\e[1m"
  GREEN = "\e[32m"
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

    lines = [header(rows), '']
    lines.concat(zip_columns(dataset_block(rows), index_block(tasks)))
    lines = clamp_width(lines)
    limit_height ? clamp_height(lines) : lines
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
      # A blank line below each bar for breathing room (the divider continues).
      rows.each { |r| lines << dataset_line(r) << '' }
    end
    lines
  end

  def index_block(tasks)
    lines = ['INDEX BUILDS', '']
    if tasks.empty?
      lines << '  (none building)'
    else
      tasks.sort_by(&:label).each { |t| lines << index_line(t) << '' }
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
    "  #{cell(row[:type], DS_NAME_WIDTH)} #{bar(ratio, DS_BAR_WIDTH)} #{pct(ratio)}  #{counts.ljust(DS_COUNT_WIDTH)} #{status}"
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
    CouchdbIndexProgress.idle? && (monotonic - @last_change_at) > @idle_exit
  end

  def print_summary
    rows = SyncProgress.snapshot
    done = rows.count { |r| r[:status] == 'done' }
    failed = rows.select { |r| r[:status] == 'failed' }
    @output.puts
    @output.puts "Progress watch interrupted (sync continues in the background)." if @interrupted
    @output.puts bold("Sync state: #{done}/#{rows.size} datasets done.")
    failed.each { |r| @output.puts "  failed  #{r[:type]}: #{r[:message]}" }
    @output.puts '  (timed out waiting for activity — sync may still be running)' if idle_timed_out? && !finished?
  end

  def elapsed
    secs = (monotonic - @started_at).to_i
    secs < 60 ? "#{secs}s" : "#{secs / 60}m#{(secs % 60).to_s.rjust(2, '0')}s"
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
