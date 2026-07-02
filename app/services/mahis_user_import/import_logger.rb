# frozen_string_literal: true

require 'fileutils'

module MahisUserImport
  class ImportLogger
    attr_reader :path

    def initialize(output: $stdout)
      @output = output
      FileUtils.mkdir_p(Rails.root.join('log'))
      @path = Rails.root.join('log', "mahis-user-import-#{Time.current.strftime('%Y%m%d-%H%M%S')}.log")
      @file = File.open(@path, 'a')
    end

    def info(message)
      write('INFO', message)
    end

    def row(row_number:, status:, username:, messages: [])
      message = [
        "row=#{row_number}",
        "status=#{status}",
        "username=#{username.presence || '(blank)'}",
        Array(messages).reject(&:blank?).join('; ')
      ].reject(&:blank?).join(' ')

      info(message)
    end

    def summary(summary)
      info(
        'summary ' \
        "total_rows=#{summary[:total_rows]} " \
        "created_users=#{summary[:created_users]} " \
        "updated_existing_users=#{summary[:updated_existing_users]} " \
        "skipped_duplicates=#{summary[:skipped_duplicates]} " \
        "failed_rows=#{summary[:failed_rows]} " \
        "dry_run_valid_rows=#{summary[:dry_run_valid_rows]} " \
        "dry_run_invalid_rows=#{summary[:dry_run_invalid_rows]}"
      )
      info("log_file=#{@path}")
    end

    def close
      @file&.close
    end

    private

    def write(level, message)
      line = "#{Time.current.iso8601} #{level} #{mask(message)}"
      @file.puts(line)
      @file.flush
      Rails.logger.info(line)
      @output.puts(line)
    end

    def mask(message)
      message.to_s
             .gsub(/(password\s*[:=]\s*)([^,\s;]+)/i, '\1[MASKED]')
             .gsub(/(admin_password\s*[:=]\s*)([^,\s;]+)/i, '\1[MASKED]')
    end
  end
end
