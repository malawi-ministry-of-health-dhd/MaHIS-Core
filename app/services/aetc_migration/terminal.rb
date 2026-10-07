# frozen_string_literal: true

module AetcMigration
  # Terminal output for the aetc:* tasks: headings, ✓/!/✗ lines, tables, progress bars and prompts.
  # Every line is also written (without colours) to log/aetc-migration-<timestamp>.log.
  class Terminal
    COLORS = { bold: 1, red: 31, green: 32, yellow: 33, cyan: 36, gray: 90 }.freeze
    WIDTH = 72

    attr_reader :log_path

    def initialize(output: $stdout, input: $stdin, log_dir: nil, color: nil)
      @output = output
      @input = input
      @color = color.nil? ? (tty? && ENV['NO_COLOR'].blank?) : color
      open_log(log_dir) if log_dir
    end

    def title(text)
      line = "━━ #{text} "
      puts_both('', '')
      puts_both(paint(line.ljust(WIDTH, '━'), :bold, :cyan), line)
    end

    def section(text)
      puts_both('', '')
      puts_both(paint("▸ #{text}", :bold), "== #{text}")
    end

    def info(text)
      puts_both("  #{text}", text)
    end

    def ok(text)
      puts_both("  #{paint('✓', :green)} #{text}", "[OK] #{text}")
    end

    def warn(text)
      puts_both("  #{paint('!', :yellow)} #{paint(text, :yellow)}", "[WARN] #{text}")
    end

    def error(text)
      puts_both("  #{paint('✗', :red)} #{paint(text, :red)}", "[ERROR] #{text}")
    end

    def detail(text)
      puts_both("    #{paint(text, :gray)}", "  #{text}")
    end

    # Label/value pairs, aligned.
    def summary(pairs)
      width = pairs.keys.map { |k| k.to_s.length }.max.to_i
      pairs.each { |label, value| info("#{label.to_s.ljust(width)}  #{format_cell(value)}") }
    end

    # Columns are left-aligned; numbers are right-aligned with thousands separators.
    def table(headers, rows)
      cells = rows.map { |row| row.map { |v| format_cell(v) } }
      widths = headers.each_index.map { |i| ([headers[i].to_s] + cells.map { |r| r[i].to_s }).map(&:length).max }
      numeric = headers.each_index.map { |i| rows.any? && rows.all? { |r| r[i].nil? || r[i].is_a?(Numeric) } }
      render = lambda do |row|
        row.each_with_index.map { |v, i| numeric[i] ? v.to_s.rjust(widths[i]) : v.to_s.ljust(widths[i]) }.join('  ')
      end
      head = render.call(headers.map(&:to_s))
      puts_both("  #{paint(head, :bold)}", head)
      rule = widths.map { |w| '─' * w }.join('  ')
      puts_both("  #{paint(rule, :gray)}", rule)
      cells.each { |row| info(render.call(row)) }
    end

    # Yields a Progress; returns the block's value. bytes: true shows sizes and transfer rate.
    def progress(title, total:, bytes: false)
      bar = Progress.new(self, title, total, bytes: bytes)
      started = monotonic
      result = yield bar
      bar.finish
      done = bytes ? number_to_size(bar.current) : number(bar.current)
      ok("#{title}: #{done} in #{duration(monotonic - started)}")
      result
    end

    # Prints the prompt and returns the stripped answer, or nil when there is no input (EOF).
    def ask(prompt)
      @output.print("  #{paint('?', :cyan)} #{prompt} ")
      @output.flush
      answer = @input.gets&.strip
      @output.puts if answer.nil?
      log_line("[ASK] #{prompt} -> #{answer.nil? ? '(no input)' : answer.inspect}")
      answer
    end

    def tty?
      @output.respond_to?(:tty?) && @output.tty?
    end

    def number(value)
      ActiveSupport::NumberHelper.number_to_delimited(value)
    end

    def number_to_size(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes, precision: 3)
    end

    def duration(seconds)
      seconds = seconds.round
      return "#{seconds}s" if seconds < 60
      return format('%<m>dm %<s>02ds', m: seconds / 60, s: seconds % 60) if seconds < 3600

      format('%<h>dh %<m>02dm', h: seconds / 3600, m: (seconds % 3600) / 60)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def output
      @output
    end

    def log_line(text)
      return unless @log

      @log.puts("#{Time.current.strftime('%Y-%m-%d %H:%M:%S')} #{text}")
      @log.flush
    end

    def close
      @log&.close
      @log = nil
    end

    private

    def puts_both(screen, logged)
      @output.puts(screen)
      log_line(logged) unless logged.empty?
    end

    def paint(text, *styles)
      return text unless @color

      "\e[#{styles.map { |s| COLORS.fetch(s) }.join(';')}m#{text}\e[0m"
    end

    def format_cell(value)
      value.is_a?(Integer) ? number(value) : value.to_s
    end

    def open_log(dir)
      FileUtils.mkdir_p(dir)
      @log_path = Pathname(dir).join("aetc-migration-#{Time.current.strftime('%Y%m%d-%H%M%S')}.log")
      @log = File.open(@log_path, 'a')
    end

    # A progress bar on a terminal (tty-progressbar); a line every 10% when output is redirected.
    class Progress
      attr_reader :current

      def initialize(terminal, title, total, bytes:)
        @terminal = terminal
        @title = title
        @total = total.to_i
        @bytes = bytes
        @current = 0
        @next_step = 10
        @terminal.log_line("[START] #{title} (#{bytes ? terminal.number_to_size(@total) : terminal.number(@total)})")
        @bar = build_bar if terminal.tty? && @total.positive?
      end

      def advance(step = 1)
        @current += step
        if @bar
          @bar.advance(step)
        else
          report_plain
        end
      end

      # Prints a message above the bar without breaking it.
      def log(message)
        @bar ? @bar.log("  #{message}") : @terminal.output.puts("  #{message}")
        @terminal.log_line(message)
      end

      def finish
        @bar&.finish
      end

      private

      def build_bar
        require 'tty-progressbar'
        counts = @bytes ? ':current_byte/:total_byte  :byte_rate/s' : ':current/:total  :rate/s'
        TTY::ProgressBar.new("  #{@title} [:bar] :percent  #{counts}  ETA :eta",
                             total: @total, width: 30, complete: '█', incomplete: '░',
                             output: @terminal.output, frequency: 10, hide_cursor: true)
      end

      def report_plain
        return unless @total.positive?

        percent = (@current * 100) / @total
        return if percent < @next_step

        done = @bytes ? @terminal.number_to_size(@current) : @terminal.number(@current)
        @terminal.output.puts("  #{@title}: #{[percent, 100].min}% (#{done})")
        @next_step = ((percent / 10) + 1) * 10
      end
    end
  end
end
