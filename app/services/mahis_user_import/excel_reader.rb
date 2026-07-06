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
      opd_activities
      aetc_activities
      ncd_activities
      opd_waiting_list
    ].freeze
    OPTIONAL_COLUMNS = %w[
      username
      password
      waiting_list_access
      activities
      opd_activities
      aetc_activities
      ncd_activities
      opd_waiting_list
    ].freeze
    REQUIRED_COLUMNS = (EXPECTED_COLUMNS - OPTIONAL_COLUMNS).freeze
    HEADER_SCAN_ROWS = 10
    HEADER_ALIASES = {
      'program_in_mahis' => 'program',
      'role_in_mahis' => 'role',
      'activities_in_mahis' => 'activities',
      'opd_activities_in_mahis' => 'opd_activities',
      'aetc_activities_in_mahis' => 'aetc_activities',
      'ncd_activities_in_mahis' => 'ncd_activities',
      'opd_waiting_lists' => 'opd_waiting_list',
      'opd_waiting_list_in_mahis' => 'opd_waiting_list',
      'opd_waiting_lists_in_mahis' => 'opd_waiting_list'
    }.freeze

    Row = Struct.new(:number, :sheet_name, :sheet_index, :row_number, :data, keyword_init: true)

    def initialize(file_path)
      @file_path = Pathname(file_path)
    end

    def read
      workbook = Roo::Spreadsheet.open(@file_path.to_s)
      rows = workbook.sheets.each_with_index.flat_map do |sheet_name, sheet_index|
        read_sheet(workbook.sheet(sheet_name), sheet_name, sheet_index)
      end

      raise ArgumentError, "Excel file is empty: #{@file_path}" if rows.empty?

      rows
    end

    private

    def read_sheet(sheet, sheet_name, sheet_index)
      return [] if sheet.last_row.blank? || sheet.last_row < 1

      header_row_number = find_header_row_number(sheet, sheet_name)
      headers = normalized_headers(sheet, header_row_number)
      validate_headers!(headers, header_row_number, sheet_name)

      ((header_row_number + 1)..sheet.last_row).filter_map do |row_number|
        data = row_data(sheet, headers, row_number)
        next if data.values.all?(&:blank?)

        Row.new(
          number: row_label(sheet_name, row_number),
          sheet_name: sheet_name,
          sheet_index: sheet_index,
          row_number: row_number,
          data: data
        )
      end
    end

    def find_header_row_number(sheet, sheet_name)
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
            "Excel header row was not found in sheet '#{sheet_name}' in the first #{HEADER_SCAN_ROWS} rows. " \
            "Best candidate row #{best_row_number} is missing required columns: #{missing.join(', ')}"
    end

    def normalized_headers(sheet, row_number)
      (1..sheet.last_column).map do |column|
        normalize_header(cell_value(sheet, row_number, column))
      end
    end

    def validate_headers!(headers, header_row_number, sheet_name)
      present_headers = headers.reject(&:blank?)
      missing = REQUIRED_COLUMNS - present_headers
      if missing.any?
        raise ArgumentError,
              "Excel header row #{header_row_number} in sheet '#{sheet_name}' is missing required columns: " \
              "#{missing.join(', ')}"
      end

      duplicates = present_headers.tally.select { |_header, count| count > 1 }.keys
      if duplicates.any?
        raise ArgumentError,
              "Excel header row #{header_row_number} in sheet '#{sheet_name}' has duplicate columns: " \
              "#{duplicates.join(', ')}"
      end
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

    def row_label(sheet_name, row_number)
      "#{sheet_name.to_s.squish.tr(' ', '_')}:#{row_number}"
    end
  end
end
