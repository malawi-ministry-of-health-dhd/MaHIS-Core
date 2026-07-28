# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'

# Usage:
#   bin/rails ncd_identifiers:fix                         # preview
#   bin/rails ncd_identifiers:fix_all_abnormal
#   DRY_RUN=false SYNC_COUCHDB=true bin/rails ncd_identifiers:fix
#
# The narrower normalize_spaces and apply_undefined_prefixes tasks are
# preview-only. All writes go through the locked, collision-safe full cleanup.
#
# Facility prefix mapping defaults to db/ncd_facility_prefix_mapping.json.
# The task targets NDC_mahis by default. Override with DB_NAME=other_database.
class NcdIdentifierCleanupTask
  DEFAULT_DATABASE = 'NDC_mahis'
  DEFAULT_IDENTIFIER_TYPE = 31
  DEFAULT_MAPPING_PATH = Rails.root.join('db', 'ncd_facility_prefix_mapping.json')
  DEFAULT_DETAILS_PATH = Rails.root.join('tmp', 'ncd_undefined_facility_details.json')
  DEFAULT_REVIEW_PATH = Rails.root.join('tmp', 'ncd_abnormal_identifier_review.json')
  DEFAULT_MAX_NEXT_NUMBER_SOURCE = 100_000
  NCD_NUMBER_LOCK_NAME = 'mahis_ncd_number_allocation'
  NCD_NUMBER_LOCK_TIMEOUT = 30
  VALID_COLLISION_MODES = %w[next review].freeze
  STANDARD_IDENTIFIER = /\A[A-Z]+-NCD-\d+\z/

  def initialize(database_name:, identifier_type:, mapping_path:, details_path:, review_path:, dry_run:,
                 collision_mode:, max_next_number_source:, sync_couchdb: false)
    @database_name = validate_database_name(database_name)
    @identifier_type = identifier_type.to_i
    @mapping_path = mapping_path.to_s
    @details_path = details_path.to_s
    @review_path = review_path.to_s
    @dry_run = dry_run
    @collision_mode = collision_mode.to_s.downcase
    @max_next_number_source = max_next_number_source.to_i
    @sync_couchdb = sync_couchdb

    unless VALID_COLLISION_MODES.include?(@collision_mode)
      raise ArgumentError, "COLLISION_MODE must be one of: #{VALID_COLLISION_MODES.join(', ')}"
    end
    raise ArgumentError, 'IDENTIFIER_TYPE must be a positive integer' unless @identifier_type.positive?
    raise ArgumentError, 'MAX_NEXT_NUMBER_SOURCE must be a positive integer' unless @max_next_number_source.positive?
  end

  def run
    puts "\n===== NCD Identifier Cleanup ====="
    puts "Database: #{@database_name}"
    puts "Identifier type: #{@identifier_type}"
    puts "Dry run: #{@dry_run}"

    fix_all_abnormal_identifiers
  end

  def normalize_spaced_identifiers
    validate_target_database!
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

    if !@dry_run && changes.any?
      raise 'Direct space-cleanup writes are disabled; use DRY_RUN=false bin/rails ncd_identifiers:fix'
    end

    changes
  end

  def export_undefined_facility_mapping
    validate_target_database!
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
    validate_target_database!
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

    if !@dry_run && changes.any?
      raise 'Direct undefined-prefix writes are disabled; use DRY_RUN=false bin/rails ncd_identifiers:fix'
    end

    changes
  end

  def fix_all_abnormal_identifiers
    validate_target_database!
    plan = if @dry_run
             build_cleanup_plan
           else
             with_ncd_number_lock do
               locked_plan = build_cleanup_plan
               apply_changes(locked_plan[:changes])
               locked_plan
             end
           end

    changes = plan[:changes]
    unresolved = plan[:unresolved]
    warnings = plan[:warnings]
    write_review(changes, unresolved, warnings)

    puts "\n--- All abnormal NCD cleanup ---"
    puts "Changes ready: #{changes.length}"
    puts "Still needs review: #{unresolved.length}"
    puts "Warnings: #{warnings.length}"
    puts "Review JSON: #{@review_path}"
    print_sample_changes(changes.map { |change| change.merge(id: change[:patient_identifier_id]) })
    print_unresolved_sample(unresolved)
    print_warning_sample(warnings)

    unless @dry_run
      puts "Updated #{changes.length} abnormal NCD identifiers."
      enqueue_couchdb_sync(changes) if @sync_couchdb && changes.any?
    end

    changes
  end

  private

  def build_cleanup_plan
    rows = all_identifier_rows
    reservation_rows = all_identifier_reservation_rows
    mapping = load_json_hash(@mapping_path)
    prefix_by_facility_name = mapping.each_with_object({}) do |(facility_name, value), result|
      prefix = mapping_prefix(value)
      next if blank?(prefix)

      result[facility_name] = prefix.upcase
    end

    reserved_identifiers = reservation_rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, result|
      result[identifier_collision_key(row['identifier'])] << row.dup
    end
    used_number_groups = build_used_number_groups(reservation_rows)

    changes = []
    unresolved = []
    warnings = []
    rows.each do |row|
      identifier = row['identifier'].to_s
      if identifier.match?(STANDARD_IDENTIFIER)
        expected_prefix = prefix_by_facility_name[row['facility_name'].to_s]
        actual_prefix = identifier.split('-NCD-', 2).first
        if expected_prefix.present? && actual_prefix != expected_prefix
          warnings << warning_payload(
            row,
            reason: 'prefix differs from the current mapped facility',
            suggestion: identifier.sub(/\A[A-Z]+-NCD-/, "#{expected_prefix}-NCD-")
          ).merge(row_review_payload(row))
        end

        conflicts = conflicting_reservations(row, identifier, reserved_identifiers)
        next if conflicts.empty? || standard_duplicate_keeper?(row, conflicts)

        if same_patient_active_conflict?(row, conflicts)
          unresolved << unresolved_payload(
            row,
            reason: 'same patient has duplicate active NCD identifier rows',
            suggestion: 'review and void the redundant patient_identifier row'
          ).merge(row_review_payload(row))
          next
        end

        if @collision_mode == 'review'
          unresolved << unresolved_payload(
            row,
            reason: 'NCD identifier is already reserved by another row',
            suggestion: next_available_identifier(actual_prefix, reserved_identifiers, used_number_groups, row)
          ).merge(row_review_payload(row))
          next
        end

        replacement = next_available_identifier(actual_prefix, reserved_identifiers, used_number_groups, row)
        if replacement.blank?
          unresolved << unresolved_payload(row, reason: 'NCD number range exhausted').merge(row_review_payload(row))
          next
        end

        proposed = change_payload(row, replacement, 'duplicate_identifier_next_number')
        proposed[:collision_reservations] = collision_review_payload(conflicts)
      else
        proposed = propose_standard_identifier(row, prefix_by_facility_name, reserved_identifiers, used_number_groups)
      end

      if proposed[:new_identifier].blank?
        unresolved << proposed.merge(row_review_payload(row))
        next
      end

      conflicts = conflicting_reservations(row, proposed[:new_identifier], reserved_identifiers)
      if conflicts.any?
        proposed[:collision_reservations] = collision_review_payload(conflicts)
        if same_patient_active_conflict?(row, conflicts)
          unresolved << proposed.merge(
            row_review_payload(row),
            new_identifier: nil,
            reason: 'same patient has duplicate active NCD identifier rows',
            suggestion: 'review and void the redundant patient_identifier row'
          )
          next
        end

        case @collision_mode
        when 'next'
          proposed[:collision_original_identifier] = proposed[:new_identifier]
          proposed[:new_identifier] = next_available_identifier(
            proposed[:new_identifier].split('-NCD-', 2).first,
            reserved_identifiers,
            used_number_groups,
            row
          )
          if proposed[:new_identifier].blank?
            unresolved << proposed.merge(
              row_review_payload(row),
              new_identifier: nil,
              reason: 'NCD number range exhausted'
            )
            next
          end
          proposed[:category] = "#{proposed[:category]}_collision_next_number"
        else
          unresolved << proposed.merge(
            row_review_payload(row),
            new_identifier: nil,
            reason: 'target identifier is already reserved',
            suggestion: next_available_identifier(
              proposed[:new_identifier].split('-NCD-', 2).first,
              reserved_identifiers,
              used_number_groups,
              row
            )
          )
          next
        end
      end

      reserve_change!(row, proposed[:new_identifier], reserved_identifiers)
      track_used_number(proposed[:new_identifier], row, used_number_groups)
      changes << proposed.merge(row_review_payload(row))
    end

    { changes: changes, unresolved: unresolved, warnings: warnings }
  end

  def write_review(changes, unresolved, warnings)
    write_json(@review_path, {
      database: @database_name,
      identifier_type: @identifier_type,
      dry_run: @dry_run,
      collision_mode: @collision_mode,
      max_next_number_source: @max_next_number_source,
      change_count: changes.length,
      unresolved_count: unresolved.length,
      warning_count: warnings.length,
      changes_by_category: changes.group_by { |change| change[:category] }.transform_values(&:length),
      unresolved_by_reason: unresolved.group_by { |item| item[:reason] }.transform_values(&:length),
      warnings_by_reason: warnings.group_by { |item| item[:reason] }.transform_values(&:length),
      changes: changes,
      unresolved: unresolved,
      warnings: warnings
    })
  end

  def apply_changes(changes)
    return if changes.empty?

    connection.transaction do
      changes.each do |change|
        affected = update_sanitized(
          <<~SQL.squish,
            UPDATE #{table('patient_identifier')}
            SET identifier = ?
            WHERE patient_identifier_id = ?
              AND identifier_type = ?
              AND voided = 0
              AND identifier = ?
          SQL
          change[:new_identifier],
          change[:patient_identifier_id],
          @identifier_type,
          change[:old_identifier]
        )
        next if affected == 1

        raise "NCD identifier #{change[:patient_identifier_id]} changed after the cleanup plan was built"
      end
    end
  end

  def connection
    ActiveRecord::Base.connection
  end

  def all_identifier_rows
    join_sql = facility_join_sql
    connection.select_all(<<~SQL).to_a
      SELECT
        pi.patient_identifier_id,
        pi.patient_id,
        pi.identifier,
        pi.location_id AS identifier_location_id,
        pi.date_created,
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

  def all_identifier_reservation_rows
    connection.select_all(<<~SQL).to_a
      SELECT
        patient_identifier_id,
        patient_id,
        identifier,
        location_id AS identifier_location_id,
        voided
      FROM #{table('patient_identifier')}
      WHERE identifier_type = #{@identifier_type}
      ORDER BY patient_identifier_id
    SQL
  end

  def undefined_identifier_rows
    join_sql = facility_join_sql
    connection.select_all(<<~SQL).to_a
      SELECT
        pi.patient_identifier_id,
        pi.patient_id,
        pi.identifier,
        pi.location_id AS identifier_location_id,
        pi.date_created,
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
        pi.patient_id,
        pi.identifier,
        pi.location_id AS identifier_location_id,
        pi.date_created,
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
      joins << <<~SQL.squish
        LEFT JOIN #{table('facilities')} facility_by_creator_code
          ON BINARY facility_by_creator_code.code = BINARY creator_user.location_id
      SQL

      if column_exists?('facilities', 'id')
        joins << <<~SQL.squish
          LEFT JOIN #{table('facilities')} facility_by_identifier_location
            ON facility_by_identifier_location.id = pi.location_id
        SQL
        joins << <<~SQL.squish
          LEFT JOIN #{table('facilities')} facility_by_creator_id
            ON creator_user.location_id REGEXP '^[0-9]+$'
           AND facility_by_creator_id.id = CAST(creator_user.location_id AS UNSIGNED)
        SQL
        facility_name_parts << 'facility_by_identifier_location.name'
        facility_code_parts << 'facility_by_identifier_location.code'
        facility_name_parts << 'facility_by_creator_id.name'
        facility_code_parts << 'facility_by_creator_id.code'
      end

      facility_name_parts << 'facility_by_creator_code.name'
      facility_code_parts << 'facility_by_creator_code.code'
    end

    if table_exists?('location')
      joins << <<~SQL.squish
        LEFT JOIN #{table('location')} identifier_location
          ON identifier_location.location_id = pi.location_id
      SQL
      joins << <<~SQL.squish
        LEFT JOIN #{table('location')} creator_location
          ON creator_user.location_id REGEXP '^[0-9]+$'
         AND creator_location.location_id = CAST(creator_user.location_id AS UNSIGNED)
      SQL
      facility_name_parts.unshift('identifier_location.name')
      facility_name_parts << 'creator_location.name'
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

  def propose_standard_identifier(row, prefix_by_facility_name, reserved_identifiers, used_number_groups)
    old_identifier = row['identifier'].to_s
    normalized = normalize_ncd_identifier(old_identifier)
    return change_payload(row, normalized, 'spacing') if normalized.match?(STANDARD_IDENTIFIER)

    case normalized
    when /\A(undefined|null)-NCD-\z/i
      return missing_number_change(row, prefix_by_facility_name, reserved_identifiers, used_number_groups)
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
      return missing_number_change(row, prefix_by_facility_name, reserved_identifiers, used_number_groups)
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

      replacement = next_available_identifier(prefix, reserved_identifiers, used_number_groups, row)
      return unresolved_payload(row, reason: 'NCD number range exhausted') if replacement.blank?

      return change_payload(row, replacement, 'invalid_suffix_next')
    end

    unresolved_payload(row, reason: 'no safe automatic rule')
  end

  def mapped_prefix_change(row, number, prefix_by_facility_name, category: 'mapped_prefix')
    prefix = prefix_by_facility_name[row['facility_name'].to_s]
    return unresolved_payload(row, reason: 'missing facility prefix mapping') if blank?(prefix)

    change_payload(row, "#{prefix}-NCD-#{number}", category)
  end

  def missing_number_change(row, prefix_by_facility_name, reserved_identifiers, used_number_groups)
    prefix = row['identifier'].to_s.match(/\A([A-Za-z]+)-NCD-\z/i)&.[](1)&.upcase
    prefix = prefix_by_facility_name[row['facility_name'].to_s] if %w[UNDEFINED NULL].include?(prefix.to_s)
    return unresolved_payload(row, reason: 'missing facility prefix mapping') if blank?(prefix)

    replacement = next_available_identifier(prefix, reserved_identifiers, used_number_groups, row)
    return unresolved_payload(row, reason: 'NCD number range exhausted') if replacement.blank?

    change_payload(row, replacement, 'missing_number_next')
  end

  def next_available_identifier(prefix, reserved_identifiers, used_number_groups, row)
    prefix = prefix.to_s.upcase
    used_numbers = used_number_groups[prefix]
    next_number = 1
    next_number += 1 while used_numbers.include?(next_number)
    return nil if next_number > @max_next_number_source

    candidate = "#{prefix}-NCD-#{next_number}"
    while conflicting_reservations(row, candidate, reserved_identifiers).any?
      next_number += 1
      return nil if next_number > @max_next_number_source

      candidate = "#{prefix}-NCD-#{next_number}"
    end
    candidate
  end

  def build_used_number_groups(rows)
    rows.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |row, result|
      track_used_number(row['identifier'].to_s, row, result)
    end
  end

  def track_used_number(identifier, _row, used_number_groups)
    match = normalize_ncd_identifier(identifier).match(/\A([A-Za-z]+)-NCD-(\d+)\z/i)
    return unless match

    prefix = match[1].upcase
    number = match[2].to_i
    return if @max_next_number_source.positive? && number > @max_next_number_source

    used_number_groups[prefix] << number
  end

  def identifier_collision_key(identifier)
    normalize_ncd_identifier(identifier).upcase
  end

  def conflicting_reservations(row, identifier, reserved_identifiers)
    reserved_identifiers.fetch(identifier_collision_key(identifier), []).reject do |reservation|
      same_row = reservation['patient_identifier_id'].to_i == row['patient_identifier_id'].to_i
      same_patient_history = reservation['voided'].to_i != 0 &&
                             reservation['patient_id'].to_i == row['patient_id'].to_i
      same_row || same_patient_history
    end
  end

  def collision_review_payload(conflicts)
    conflicts.map do |conflict|
      {
        patient_identifier_id: conflict['patient_identifier_id'].to_i,
        patient_id: conflict['patient_id'].to_i,
        voided: conflict['voided'].to_i
      }
    end
  end

  def standard_duplicate_keeper?(row, conflicts)
    return false if conflicts.any? { |conflict| conflict['voided'].to_i != 0 }

    active_ids = conflicts.map { |conflict| conflict['patient_identifier_id'].to_i }
    row['patient_identifier_id'].to_i == ([row['patient_identifier_id'].to_i] + active_ids).min
  end

  def same_patient_active_conflict?(row, conflicts)
    conflicts.any? do |conflict|
      conflict['voided'].to_i.zero? && conflict['patient_id'].to_i == row['patient_id'].to_i
    end
  end

  def reserve_change!(row, new_identifier, reserved_identifiers)
    old_key = identifier_collision_key(row['identifier'])
    reserved_identifiers[old_key].reject! do |reservation|
      reservation['patient_identifier_id'].to_i == row['patient_identifier_id'].to_i
    end
    reserved_identifiers[identifier_collision_key(new_identifier)] << row.merge(
      'identifier' => new_identifier,
      'voided' => 0
    )
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

  def warning_payload(row, reason:, suggestion: nil)
    {
      category: 'warning',
      old_identifier: row['identifier'].to_s,
      new_identifier: nil,
      reason: reason,
      suggestion: suggestion
    }
  end

  def row_review_payload(row)
    {
      patient_identifier_id: row['patient_identifier_id'].to_i,
      patient_id: row['patient_id']&.to_i,
      creator: row['creator'],
      identifier_location_id: row['identifier_location_id'],
      user_location_id: row['user_location_id'],
      facility_name: row['facility_name'],
      matched_facility_code: row['matched_facility_code']
    }
  end

  def update_sanitized(sql, *binds)
    connection.update(ActiveRecord::Base.sanitize_sql_array([sql, *binds]))
  end

  def with_ncd_number_lock
    lock_name = connection.quote(NCD_NUMBER_LOCK_NAME)
    acquired = connection.select_value("SELECT GET_LOCK(#{lock_name}, #{NCD_NUMBER_LOCK_TIMEOUT})")
    raise 'Timed out acquiring the NCD number allocation lock' unless acquired.to_i == 1

    yield
  ensure
    connection.select_value("SELECT RELEASE_LOCK(#{lock_name})") if acquired.to_i == 1
  end

  def validate_target_database!
    database_exists = connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
                                              'SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?',
                                              @database_name
                                            ])
    ).to_i.positive?
    raise "Database #{@database_name} does not exist" unless database_exists
    raise "Table #{@database_name}.patient_identifier does not exist" unless table_exists?('patient_identifier')

    return unless table_exists?('patient_identifier_type')

    identifier_type_name = connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
                                              <<~SQL.squish,
                                                SELECT name
                                                FROM #{table('patient_identifier_type')}
                                                WHERE patient_identifier_type_id = ?
                                              SQL
                                              @identifier_type
                                            ])
    ).to_s
    return if identifier_type_name.casecmp?('NCD Number')

    raise "Identifier type #{@identifier_type} is #{identifier_type_name.inspect}, not \"NCD Number\""
  end

  def enqueue_couchdb_sync(changes)
    current_database = connection.select_value('SELECT DATABASE()').to_s
    unless current_database.casecmp?(@database_name)
      puts "Skipped CouchDB sync: Rails is connected to #{current_database}, not #{@database_name}."
      return
    end

    patient_ids = changes.filter_map { |change| change[:patient_id] }.uniq
    patient_ids.each_slice(100) do |ids|
      Sync::BulkPatientRecordSyncJob.perform_async(ids, { 'source' => 'ncd_identifier_cleanup' })
    end
    puts "Queued CouchDB refresh for #{patient_ids.length} patients."
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

  def print_warning_sample(warnings)
    return if warnings.empty?

    puts "Warning examples (not changed automatically):"
    warnings.first(10).each do |item|
      suggestion = item[:suggestion] ? " possible local format: #{item[:suggestion]}" : ''
      puts "  #{item[:patient_identifier_id]}: #{item[:old_identifier]} (#{item[:reason]})#{suggestion}"
    end
    puts "  ... #{warnings.length - 10} more" if warnings.length > 10
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
  desc 'Preview or run the full NCD identifier cleanup against NDC_mahis'
  task fix: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE),
      sync_couchdb: ENV.fetch('SYNC_COUCHDB', 'false') == 'true'
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
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE),
      sync_couchdb: ENV.fetch('SYNC_COUCHDB', 'false') == 'true'
    ).fix_all_abnormal_identifiers
  end

  desc 'Preview identifiers with spaces (writes must use ncd_identifiers:fix)'
  task normalize_spaces: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE),
      sync_couchdb: false
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
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE),
      sync_couchdb: false
    ).export_undefined_facility_mapping
  end

  desc 'Preview undefined-prefix replacements (writes must use ncd_identifiers:fix)'
  task apply_undefined_prefixes: :environment do
    NcdIdentifierCleanupTask.new(
      database_name: ENV.fetch('DB_NAME', NcdIdentifierCleanupTask::DEFAULT_DATABASE),
      identifier_type: ENV.fetch('IDENTIFIER_TYPE', NcdIdentifierCleanupTask::DEFAULT_IDENTIFIER_TYPE),
      mapping_path: ENV.fetch('MAPPING_PATH', NcdIdentifierCleanupTask::DEFAULT_MAPPING_PATH),
      details_path: ENV.fetch('DETAILS_PATH', NcdIdentifierCleanupTask::DEFAULT_DETAILS_PATH),
      review_path: ENV.fetch('REVIEW_PATH', NcdIdentifierCleanupTask::DEFAULT_REVIEW_PATH),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      collision_mode: ENV.fetch('COLLISION_MODE', 'next'),
      max_next_number_source: ENV.fetch('MAX_NEXT_NUMBER_SOURCE', NcdIdentifierCleanupTask::DEFAULT_MAX_NEXT_NUMBER_SOURCE),
      sync_couchdb: ENV.fetch('SYNC_COUCHDB', 'false') == 'true'
    ).apply_undefined_prefix_mapping
  end
end
