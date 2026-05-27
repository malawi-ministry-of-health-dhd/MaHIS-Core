# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'

# Usage:
#   DRY_RUN=false bin/rails ncd_identifiers:fix_all_abnormal 
#
#   bin/rails ncd_identifiers:fix
#   bin/rails ncd_identifiers:fix_all_abnormal
#   DRY_RUN=false bin/rails ncd_identifiers:normalize_spaces
#   DRY_RUN=false bin/rails ncd_identifiers:apply_undefined_prefixes
#
# Facility prefix mapping defaults to db/ncd_facility_prefix_mapping.json.
# The task targets mahis_pro by default. Override with DB_NAME=other_database.
class NcdIdentifierCleanupTask
  DEFAULT_DATABASE = 'mahis_pro'
  DEFAULT_IDENTIFIER_TYPE = 31
  DEFAULT_MAPPING_PATH = Rails.root.join('db', 'ncd_facility_prefix_mapping.json')
  DEFAULT_DETAILS_PATH = Rails.root.join('tmp', 'ncd_undefined_facility_details.json')
  DEFAULT_REVIEW_PATH = Rails.root.join('tmp', 'ncd_abnormal_identifier_review.json')
  DEFAULT_MAX_NEXT_NUMBER_SOURCE = 100_000
  STANDARD_IDENTIFIER = /\A[A-Z]+-NCD-\d+\z/

  def initialize(database_name:, identifier_type:, mapping_path:, details_path:, review_path:, dry_run:,
                 collision_mode:, max_next_number_source:)
    @database_name = validate_database_name(database_name)
    @identifier_type = identifier_type.to_i
    @mapping_path = mapping_path.to_s
    @details_path = details_path.to_s
    @review_path = review_path.to_s
    @dry_run = dry_run
    @collision_mode = collision_mode.to_s
    @max_next_number_source = max_next_number_source.to_i
  end

  def run
    puts "\n===== NCD Identifier Cleanup ====="
    puts "Database: #{@database_name}"
    puts "Identifier type: #{@identifier_type}"
    puts "Dry run: #{@dry_run}"

    fix_all_abnormal_identifiers
  end

  def normalize_spaced_identifiers
    rows = connection.select_all(<<~SQL).to_a
      SELECT patient_identifier_id, identifier
      FROM #{table('patient_identifier')}
      WHERE identifier_type = #{@identifier_type}
        AND voided = 0
        AND identifier LIKE '%NCD%'
        AND identifier REGEXP '[[:space:]]'
      ORDER BY patient_identifier_id
    SQL

    changes = rows.filter_map do |row|
      old_identifier = row['identifier'].to_s
      new_identifier = normalize_ncd_identifier(old_identifier)
      next if new_identifier == old_identifier

      {
        id: row['patient_identifier_id'],
        old_identifier: old_identifier,
        new_identifier: new_identifier
      }
    end

    puts "\n--- Space cleanup ---"
    puts "Identifiers needing cleanup: #{changes.length}"
    print_sample_changes(changes)

    return changes if @dry_run || changes.empty?

    connection.transaction do
      changes.each do |change|
        execute_sanitized(
          "UPDATE #{table('patient_identifier')} SET identifier = ? WHERE patient_identifier_id = ?",
          change[:new_identifier],
          change[:id]
        )
      end
    end

    puts "Updated #{changes.length} identifiers with spaces around -NCD-."
    changes
  end

  def export_undefined_facility_mapping
    rows = prefix_mapping_candidate_rows
    grouped_rows = rows.group_by { |row| row['facility_name'].to_s }
    existing_mapping = load_json_hash(@mapping_path)
    prefix_candidates = prefix_candidates_for_facilities(grouped_rows)

    mapping = grouped_rows.keys.sort.each_with_object({}) do |facility_name, result|
      existing_value = existing_mapping[facility_name]
      facility_codes = grouped_rows[facility_name].map { |row| row['matched_facility_code'] }.compact.uniq.sort
      existing_prefix = mapping_prefix(existing_value)
      candidates = prefix_candidates[facility_name] || []
      suggested_prefix = candidates.first&.fetch(:prefix, nil)
      result[facility_name] = {
        facility_code: facility_codes.join(', '),
        ncd_prefix: existing_prefix.presence || suggested_prefix.to_s,
        prefix_candidates: candidates
      }
    end

    details = grouped_rows.sort_by { |facility_name, _| facility_name }.map do |facility_name, facility_rows|
      {
        facility_name: facility_name,
        current_location_ids: facility_rows.map { |row| row['user_location_id'] }.compact.uniq.sort,
        matched_facility_codes: facility_rows.map { |row| row['matched_facility_code'] }.compact.uniq.sort,
        creator_ids: facility_rows.map { |row| row['creator'] }.compact.uniq.sort,
        affected_identifiers: facility_rows.length
      }
    end

    write_json(@mapping_path, mapping)
    write_json(@details_path, details)

    puts "\n--- Undefined prefix export ---"
    puts "Identifiers needing facility-prefix mapping: #{rows.length}"
    puts "Facilities needing manual NCD prefix mapping: #{mapping.length}"
    puts "Mapping JSON: #{@mapping_path}"
    puts "Details JSON: #{@details_path}"

    mapping
  end

  def apply_undefined_prefix_mapping
    mapping = load_json_hash(@mapping_path)
    prefix_by_facility_name = mapping.each_with_object({}) do |(facility_name, value), result|
      prefix = mapping_prefix(value)
      next if blank?(prefix)

      result[facility_name] = prefix
    end

    puts "\n--- Undefined prefix replacement ---"
    if prefix_by_facility_name.empty?
      puts "No filled facility prefixes found in #{@mapping_path}; nothing to replace yet."
      return []
    end

    rows = undefined_identifier_rows
    changes = rows.filter_map do |row|
      prefix = prefix_by_facility_name[row['facility_name'].to_s]
      next if blank?(prefix)

      ncd_number = ncd_number_from_identifier(row['identifier'], allow_embedded_prefix: true)
      next if blank?(ncd_number)

      new_identifier = "#{prefix}-NCD-#{ncd_number}"
      next if new_identifier == row['identifier']

      {
        id: row['patient_identifier_id'],
        old_identifier: row['identifier'].to_s,
        new_identifier: new_identifier,
        facility_name: row['facility_name'].to_s
      }
    end

    puts "Undefined identifiers with a filled prefix: #{changes.length}"
    print_sample_changes(changes)

    return changes if @dry_run || changes.empty?

    connection.transaction do
      changes.each do |change|
        execute_sanitized(
          "UPDATE #{table('patient_identifier')} SET identifier = ? WHERE patient_identifier_id = ?",
          change[:new_identifier],
          change[:id]
        )
      end
    end

    puts "Updated #{changes.length} undefined-prefix identifiers."
    changes
  end

  def fix_all_abnormal_identifiers
    rows = all_identifier_rows
    mapping = load_json_hash(@mapping_path)
    prefix_by_facility_name = mapping.each_with_object({}) do |(facility_name, value), result|
      prefix = mapping_prefix(value)
      next if blank?(prefix)

      result[facility_name] = prefix.upcase
    end

    current_identifiers = rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, result|
      result[row['identifier'].to_s] << row['patient_identifier_id'].to_i
    end
    used_identifiers = current_identifiers.transform_values(&:dup)
    used_identifiers.default_proc = proc { |hash, key| hash[key] = [] }
    used_number_groups = build_used_number_groups(rows)

    changes = []
    unresolved = []
    rows.each do |row|
      identifier = row['identifier'].to_s
      next if identifier.match?(STANDARD_IDENTIFIER)

      proposed = propose_standard_identifier(row, prefix_by_facility_name, used_identifiers, used_number_groups)
      if proposed[:new_identifier].blank?
        unresolved << proposed.merge(row_review_payload(row))
        next
      end

      if collides_with_existing_identifier?(row, proposed[:new_identifier], used_identifiers)
        case @collision_mode
        when 'next'
          proposed[:collision_original_identifier] = proposed[:new_identifier]
          proposed[:new_identifier] = next_available_identifier(
            proposed[:new_identifier].split('-NCD-', 2).first,
            used_identifiers,
            used_number_groups,
            row
          )
          proposed[:category] = "#{proposed[:category]}_collision_next_number"
        when 'keep'
          proposed[:category] = "#{proposed[:category]}_collision_kept"
        else
          unresolved << proposed.merge(row_review_payload(row), reason: 'target identifier already exists')
          next
        end
      end

      used_identifiers[proposed[:new_identifier]] << row['patient_identifier_id'].to_i
      track_used_number(proposed[:new_identifier], row, used_number_groups)
      changes << proposed.merge(row_review_payload(row))
    end

    review = {
      database: @database_name,
      identifier_type: @identifier_type,
      dry_run: @dry_run,
      collision_mode: @collision_mode,
      max_next_number_source: @max_next_number_source,
      change_count: changes.length,
      unresolved_count: unresolved.length,
      changes_by_category: changes.group_by { |change| change[:category] }.transform_values(&:length),
      unresolved_by_reason: unresolved.group_by { |item| item[:reason] }.transform_values(&:length),
      changes: changes,
      unresolved: unresolved
    }
    write_json(@review_path, review)

    puts "\n--- All abnormal NCD cleanup ---"
    puts "Changes ready: #{changes.length}"
    puts "Still needs review: #{unresolved.length}"
    puts "Review JSON: #{@review_path}"
    print_sample_changes(changes.map { |change| change.merge(id: change[:patient_identifier_id]) })
    print_unresolved_sample(unresolved)

    return changes if @dry_run || changes.empty?

    connection.transaction do
      changes.each do |change|
        execute_sanitized(
          "UPDATE #{table('patient_identifier')} SET identifier = ? WHERE patient_identifier_id = ?",
          change[:new_identifier],
          change[:patient_identifier_id]
        )
      end
    end

    puts "Updated #{changes.length} abnormal NCD identifiers."
    changes
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def all_identifier_rows
    join_sql = facility_join_sql
    connection.select_all(<<~SQL).to_a
      SELECT
        pi.patient_identifier_id,
        pi.identifier,
        pi.creator,
        creator_user.location_id AS user_location_id,
        #{join_sql[:facility_name_sql]} AS facility_name,
        #{join_sql[:facility_code_sql]} AS matched_facility_code
      FROM #{table('patient_identifier')} pi
      #{join_sql[:joins].join("\n")}
      WHERE pi.identifier_type = #{@identifier_type}
        AND pi.voided = 0
      ORDER BY pi.patient_identifier_id
    SQL
  end

  def undefined_identifier_rows
    join_sql = facility_join_sql
    connection.select_all(<<~SQL).to_a
      SELECT
        pi.patient_identifier_id,
        pi.identifier,
        pi.creator,
        creator_user.location_id AS user_location_id,
        #{join_sql[:facility_name_sql]} AS facility_name,
        #{join_sql[:facility_code_sql]} AS matched_facility_code
      FROM #{table('patient_identifier')} pi
      #{join_sql[:joins].join("\n")}
      WHERE pi.identifier_type = #{@identifier_type}
        AND pi.voided = 0
        AND LOWER(TRIM(pi.identifier)) REGEXP '^undefined[[:space:]]*-[[:space:]]*ncd[[:space:]]*-'
      ORDER BY facility_name, pi.patient_identifier_id
    SQL
  end

  def prefix_mapping_candidate_rows
    join_sql = facility_join_sql
    connection.select_all(<<~SQL).to_a
      SELECT
        pi.patient_identifier_id,
        pi.identifier,
        pi.creator,
        creator_user.location_id AS user_location_id,
        #{join_sql[:facility_name_sql]} AS facility_name,
        #{join_sql[:facility_code_sql]} AS matched_facility_code
      FROM #{table('patient_identifier')} pi
      #{join_sql[:joins].join("\n")}
      WHERE pi.identifier_type = #{@identifier_type}
        AND pi.voided = 0
        AND (
          LOWER(TRIM(pi.identifier)) REGEXP '^undefined[[:space:]]*-[[:space:]]*ncd[[:space:]]*-'
          OR LOWER(TRIM(pi.identifier)) REGEXP '^null[[:space:]]*-[[:space:]]*ncd[[:space:]]*-'
          OR TRIM(pi.identifier) REGEXP '^[0-9]+$'
          OR TRIM(pi.identifier) REGEXP '^[0-9]+[[:space:]]*-[[:space:]]*NCD[[:space:]]*-[[:space:]]*[0-9]+$'
        )
      ORDER BY facility_name, pi.patient_identifier_id
    SQL
  end

  def prefix_candidates_for_facilities(grouped_rows)
    location_ids = grouped_rows.values.flatten.map { |row| row['user_location_id'] }.compact.uniq
    return {} if location_ids.empty?

    placeholders = (['?'] * location_ids.length).join(', ')
    join_sql = facility_join_sql
    rows = connection.select_all(
      ActiveRecord::Base.sanitize_sql_array([
                                              <<~SQL.squish,
                                                SELECT
                                                  #{join_sql[:facility_name_sql]} AS facility_name,
                                                  pi.identifier
                                                FROM #{table('patient_identifier')} pi
                                                #{join_sql[:joins].join("\n")}
                                                WHERE pi.identifier_type = #{@identifier_type}
                                                  AND pi.voided = 0
                                                  AND creator_user.location_id IN (#{placeholders})
                                                  AND pi.identifier LIKE '%NCD%'
                                              SQL
                                              *location_ids
                                            ])
    ).to_a

    counts = rows.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |row, result|
      normalized = normalize_ncd_identifier(row['identifier'])
      match = normalized.match(STANDARD_IDENTIFIER)
      next unless match

      prefix = normalized.split('-NCD-', 2).first.upcase
      next if %w[UNDEFINED NULL].include?(prefix)

      result[row['facility_name'].to_s][prefix] += 1
    end

    counts.transform_values do |prefix_counts|
      prefix_counts.sort_by { |prefix, count| [-count, prefix] }.map do |prefix, count|
        {
          prefix: prefix,
          count: count
        }
      end
    end
  end

  def facility_join_sql
    facility_name_parts = []
    facility_code_parts = []
    joins = [
      "LEFT JOIN #{table('users')} creator_user ON creator_user.user_id = pi.creator"
    ]

    if table_exists?('facilities')
      joins << "LEFT JOIN #{table('facilities')} facility_by_code ON facility_by_code.code = creator_user.location_id"
      facility_name_parts << 'facility_by_code.name'
      facility_code_parts << 'facility_by_code.code'

      if column_exists?('facilities', 'id')
        joins << <<~SQL.squish
          LEFT JOIN #{table('facilities')} facility_by_id
            ON creator_user.location_id REGEXP '^[0-9]+$'
           AND facility_by_id.id = CAST(creator_user.location_id AS UNSIGNED)
        SQL
        facility_name_parts << 'facility_by_id.name'
        facility_code_parts << 'facility_by_id.code'
      end
    end

    if table_exists?('location')
      joins << <<~SQL.squish
        LEFT JOIN #{table('location')} location_by_id
          ON creator_user.location_id REGEXP '^[0-9]+$'
         AND location_by_id.location_id = CAST(creator_user.location_id AS UNSIGNED)
      SQL
      facility_name_parts << 'location_by_id.name'
    end

    facility_name_sql = coalesce_sql(
      facility_name_parts + [
        "CONCAT('UNKNOWN: creator ', pi.creator, ', location ', COALESCE(creator_user.location_id, 'NULL'))"
      ]
    )
    facility_code_sql = coalesce_sql(facility_code_parts + ['creator_user.location_id'])

    {
      joins: joins,
      facility_name_sql: facility_name_sql,
      facility_code_sql: facility_code_sql
    }
  end

  def normalize_ncd_identifier(identifier)
    identifier.to_s.strip.gsub(/[[:space:]]*-[[:space:]]*NCD[[:space:]]*-[[:space:]]*/i, '-NCD-')
  end

  def ncd_number_from_identifier(identifier, allow_embedded_prefix: false)
    normalized = normalize_ncd_identifier(identifier)
    return normalized.match(/\Aundefined-NCD-(\d+)\z/i)&.[](1) unless allow_embedded_prefix

    normalized.match(/\Aundefined-NCD-(?:[A-Za-z]+[[:space:]]*)?(\d+)\z/i)&.[](1)
  end

  def propose_standard_identifier(row, prefix_by_facility_name, used_identifiers, used_number_groups)
    old_identifier = row['identifier'].to_s
    normalized = normalize_ncd_identifier(old_identifier)
    return change_payload(row, normalized, 'spacing') if normalized.match?(STANDARD_IDENTIFIER)

    case normalized
    when /\A(undefined|null)-NCD-\z/i
      return missing_number_change(row, prefix_by_facility_name, used_identifiers, used_number_groups)
    when /\A(undefined|null)-NCD-(\d+)\z/i
      return mapped_prefix_change(row, Regexp.last_match(2), prefix_by_facility_name)
    when /\A([A-Za-z]+)--NCD-(\d+)\z/i
      return change_payload(row, "#{$1.upcase}-NCD-#{$2}", 'double_hyphen')
    when /\A([A-Za-z]+)-NCD-NCD-(\d+)\z/i
      return change_payload(row, "#{$1.upcase}-NCD-#{$2}", 'repeated_ncd')
    when /\A([A-Za-z]+)-NCD-([A-Za-z]+)[[:space:]]*(\d+)\z/i
      return mapped_prefix_change(row, Regexp.last_match(3), prefix_by_facility_name) if %w[undefined null].include?($1.downcase)

      return change_payload(row, "#{$1.upcase}-NCD-#{$3}", 'embedded_code_after_ncd')
    when /\A([A-Za-z]+)-NCD-\z/i
      return missing_number_change(row, prefix_by_facility_name, used_identifiers, used_number_groups)
    when /\A([A-Za-z]+)-NCD-(\d+)\z/i
      return mapped_prefix_change(row, Regexp.last_match(2), prefix_by_facility_name) if %w[undefined null].include?($1.downcase)

      return change_payload(row, "#{$1.upcase}-NCD-#{$2}", 'prefix_case')
    when /\A(\d+)-NCD-(\d+)\z/
      return mapped_prefix_change(row, Regexp.last_match(2), prefix_by_facility_name, category: 'numeric_prefix')
    when /\A(\d+)\z/
      return mapped_prefix_change(row, Regexp.last_match(1), prefix_by_facility_name, category: 'number_only')
    when /\A([A-Za-z]+)-NCD-.+\z/i
      prefix = Regexp.last_match(1).upcase
      return unresolved_payload(row, reason: 'missing facility prefix mapping') if %w[UNDEFINED NULL].include?(prefix)

      return change_payload(row, next_available_identifier(prefix, used_identifiers, used_number_groups, row), 'invalid_suffix_next')
    end

    unresolved_payload(row, reason: 'no safe automatic rule')
  end

  def mapped_prefix_change(row, number, prefix_by_facility_name, category: 'mapped_prefix')
    prefix = prefix_by_facility_name[row['facility_name'].to_s]
    return unresolved_payload(row, reason: 'missing facility prefix mapping') if blank?(prefix)

    change_payload(row, "#{prefix}-NCD-#{number}", category)
  end

  def missing_number_change(row, prefix_by_facility_name, used_identifiers, used_number_groups)
    prefix = row['identifier'].to_s.match(/\A([A-Za-z]+)-NCD-\z/i)&.[](1)&.upcase
    prefix = prefix_by_facility_name[row['facility_name'].to_s] if %w[UNDEFINED NULL].include?(prefix.to_s)
    return unresolved_payload(row, reason: 'missing facility prefix mapping') if blank?(prefix)

    change_payload(row, next_available_identifier(prefix, used_identifiers, used_number_groups, row), 'missing_number_next')
  end

  def next_available_identifier(prefix, used_identifiers, used_number_groups, row)
    prefix = prefix.to_s.upcase
    location_id = row['user_location_id'].to_s
    location_key = [prefix, location_id]
    global_key = [prefix, nil]
    used_numbers = if location_id.present? && used_number_groups[location_key].present?
                     used_number_groups[location_key]
                   else
                     used_number_groups[global_key]
                   end
    next_number = used_numbers.max.to_i + 1
    candidate = "#{prefix}-NCD-#{next_number}"
    while used_identifiers.fetch(candidate, []).any?
      next_number += 1
      candidate = "#{prefix}-NCD-#{next_number}"
    end
    candidate
  end

  def build_used_number_groups(rows)
    rows.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |row, result|
      track_used_number(row['identifier'].to_s, row, result)
    end
  end

  def track_used_number(identifier, row, used_number_groups)
    match = identifier.to_s.match(/\A([A-Z]+)-NCD-(\d+)\z/)
    return unless match

    prefix = match[1]
    number = match[2].to_i
    return if @max_next_number_source.positive? && number > @max_next_number_source

    location_id = row['user_location_id'].to_s
    used_number_groups[[prefix, location_id]] << number if location_id.present?
    used_number_groups[[prefix, nil]] << number
  end

  def collides_with_existing_identifier?(row, identifier, used_identifiers)
    used_identifiers.fetch(identifier, []).any? { |id| id != row['patient_identifier_id'].to_i }
  end

  def change_payload(row, new_identifier, category)
    {
      category: category,
      old_identifier: row['identifier'].to_s,
      new_identifier: new_identifier
    }
  end

  def unresolved_payload(row, reason:, suggestion: nil)
    {
      category: 'unresolved',
      old_identifier: row['identifier'].to_s,
      new_identifier: nil,
      reason: reason,
      suggestion: suggestion
    }
  end

  def row_review_payload(row)
    {
      patient_identifier_id: row['patient_identifier_id'].to_i,
      creator: row['creator'],
      user_location_id: row['user_location_id'],
      facility_name: row['facility_name'],
      matched_facility_code: row['matched_facility_code']
    }
  end

  def execute_sanitized(sql, *binds)
    connection.execute(ActiveRecord::Base.sanitize_sql_array([sql, *binds]))
  end

  def print_sample_changes(changes)
    changes.first(10).each do |change|
      puts "  #{change[:id]}: #{change[:old_identifier]} -> #{change[:new_identifier]}"
    end
    puts "  ... #{changes.length - 10} more" if changes.length > 10
  end

  def print_unresolved_sample(unresolved)
    return if unresolved.empty?

    puts "Unresolved examples:"
    unresolved.first(10).each do |item|
      suggestion = item[:suggestion] ? " suggestion: #{item[:suggestion]}" : ''
      puts "  #{item[:patient_identifier_id]}: #{item[:old_identifier]} (#{item[:reason]})#{suggestion}"
    end
    puts "  ... #{unresolved.length - 10} more" if unresolved.length > 10
  end

  def load_json_hash(path)
    return {} unless File.exist?(path)

    parsed = JSON.parse(File.read(path))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError => e
    raise "Invalid JSON in #{path}: #{e.message}"
  end

  def write_json(path, payload)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(payload)}\n")
  end

  def mapping_prefix(value)
    code = if value.is_a?(Hash)
             value['ncd_prefix'] || value['prefix']
           else
             value
           end

    code.to_s.strip
  end

  def coalesce_sql(parts)
    parts.length == 1 ? parts.first : "COALESCE(#{parts.join(', ')})"
  end

  def table_exists?(table_name)
    @table_exists ||= {}
    @table_exists[table_name] ||= connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
                                              'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?',
                                              @database_name,
                                              table_name
                                            ])
    ).to_i.positive?
  end

  def column_exists?(table_name, column_name)
    @column_exists ||= {}
    @column_exists[[table_name, column_name]] ||= connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
                                              'SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?',
                                              @database_name,
                                              table_name,
                                              column_name
                                            ])
    ).to_i.positive?
  end

  def table(table_name)
    "#{quote_identifier(@database_name)}.#{quote_identifier(table_name)}"
  end

  def quote_identifier(identifier)
    "`#{identifier}`"
  end

  def validate_database_name(database_name)
    name = database_name.to_s.strip
    raise 'DB_NAME must contain only letters, numbers, and underscores' unless name.match?(/\A[A-Za-z0-9_]+\z/)

    name
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end
end

namespace :ncd_identifiers do
  desc 'Preview or run the full NCD identifier cleanup against mahis_pro'
  task fix: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE)
    ).run
  end

  desc 'Preview or fix every non-standard NCD identifier format'
  task fix_all_abnormal: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE)
    ).fix_all_abnormal_identifiers
  end

  desc 'Preview or remove spaces around -NCD- for NCD identifiers'
  task normalize_spaces: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE)
    ).normalize_spaced_identifiers
  end

  desc 'Create JSON files for undefined-NCD identifiers grouped by creator facility'
  task export_undefined_facilities: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: true,
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE)
    ).export_undefined_facility_mapping
  end

  desc 'Replace undefined-NCD identifiers using the filled facility-prefix JSON'
  task apply_undefined_prefixes: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE)
    ).apply_undefined_prefix_mapping
  end
end
