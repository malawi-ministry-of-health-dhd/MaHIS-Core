# frozen_string_literal: true

require 'pathname'
require 'roo'

module MahisUserImport
  class ExcelReader
    EXPECTED_COLUMNS = %w[
      full_name
      first_name
      last_name
      username
      gender
      phone_number
      role
      program
      district
      facility
      password
      waiting_list_access
      activities
    ].freeze
    OPTIONAL_COLUMNS = %w[username password waiting_list_access activities].freeze
    REQUIRED_COLUMNS = (EXPECTED_COLUMNS - OPTIONAL_COLUMNS).freeze
    HEADER_SCAN_ROWS = 10
    HEADER_ALIASES = {
      'program_in_mahis' => 'program',
      'role_in_mahis' => 'role',
      'activities_in_mahis' => 'activities'
    }.freeze

    Row = Struct.new(:number, :data, keyword_init: true)

    def initialize(file_path)
      @file_path = Pathname(file_path)
    end

    def read
      workbook = Roo::Spreadsheet.open(@file_path.to_s)
      sheet = workbook.sheet(0)
      raise ArgumentError, "Excel file is empty: #{@file_path}" if sheet.last_row.blank? || sheet.last_row < 1

      header_row_number = find_header_row_number(sheet)
      headers = normalized_headers(sheet, header_row_number)
      validate_headers!(headers, header_row_number)

      ((header_row_number + 1)..sheet.last_row).filter_map do |row_number|
        data = row_data(sheet, headers, row_number)
        next if data.values.all?(&:blank?)

        Row.new(number: row_number, data: data)
      end
    end

    private

    def find_header_row_number(sheet)
      max_row = [sheet.last_row, HEADER_SCAN_ROWS].compact.min
      candidates = (1..max_row).map do |row_number|
        headers = normalized_headers(sheet, row_number)
        [row_number, headers, (headers & REQUIRED_COLUMNS).length]
      end

      exact_match = candidates.find { |_row_number, headers, _match_count| (REQUIRED_COLUMNS - headers).empty? }
      return exact_match.first if exact_match

      best_row_number, best_headers = candidates.max_by { |_row_number, _headers, match_count| match_count }
      missing = REQUIRED_COLUMNS - best_headers
      raise ArgumentError,
            "Excel header row was not found in the first #{HEADER_SCAN_ROWS} rows. " \
            "Best candidate row #{best_row_number} is missing required columns: #{missing.join(', ')}"
    end

    def normalized_headers(sheet, row_number)
      (1..sheet.last_column).map do |column|
        normalize_header(cell_value(sheet, row_number, column))
      end
    end

    def validate_headers!(headers, header_row_number)
      present_headers = headers.reject(&:blank?)
      missing = REQUIRED_COLUMNS - present_headers
      if missing.any?
        raise ArgumentError, "Excel header row #{header_row_number} is missing required columns: #{missing.join(', ')}"
      end

      duplicates = present_headers.tally.select { |_header, count| count > 1 }.keys
      raise ArgumentError, "Excel header row #{header_row_number} has duplicate columns: #{duplicates.join(', ')}" if duplicates.any?
    end

    def row_data(sheet, headers, row_number)
      headers.each_with_index.each_with_object({}) do |(header, index), data|
        next if header.blank?

        data[header] = normalize_cell_value(cell_value(sheet, row_number, index + 1))
      end.slice(*EXPECTED_COLUMNS)
    end

    def cell_value(sheet, row_number, column_number)
      sheet.formatted_value(row_number, column_number)
    rescue StandardError
      sheet.cell(row_number, column_number)
    end

    def normalize_header(value)
      I18n.transliterate(value.to_s)
          .strip
          .downcase
          .gsub(/[^a-z0-9]+/, '_')
          .gsub(/\A_|_\z/, '')
          .then { |header| HEADER_ALIASES.fetch(header, header) }
    end

    def normalize_cell_value(value)
      case value
      when NilClass
        nil
      when Numeric
        value.to_i == value ? value.to_i.to_s : value.to_s
      else
        value.to_s.strip.presence
      end
    end
  end
end
