#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../config/environment'

require 'csv'
require 'fileutils'
require 'json'
require 'optparse'
require 'securerandom'

class LocationBulkAdd
  DEFAULT_INPUT_PATH = Rails.root.join('data', 'locations_to_add.csv').to_s
  MANIFEST_DIR = Rails.root.join('tmp', 'location_import_manifests').to_s
  LATEST_MANIFEST_POINTER = Rails.root.join(MANIFEST_DIR, 'latest.json').to_s
  CLINIC_TAG_NAME = 'Village Clinic'
  SCRIPT_ID = 'location_bulk_add'

  Record = Struct.new(:name, :parent_facility_name, :clinic, :district, :line_number, keyword_init: true)

  def initialize(command:, input_path:, manifest_path:, creator_id:, dry_run:)
    @command = command
    @input_path = input_path
    @manifest_path = manifest_path
    @creator_id = creator_id
    @dry_run = dry_run
  end

  def run
    case @command
    when 'apply'
      apply
    when 'revert'
      revert
    else
      raise ArgumentError, "Unsupported command: #{@command}"
    end
  end

  private

  def apply
    assert_input_file_exists!
    records = load_records

    if records.empty?
      puts 'No rows found in input file. Nothing to apply.'
      return
    end

    clinic_tag_id = clinic_tag_id_if_needed(records)
    created = []
    skipped = []
    errors = []
    planned_rows = []
    planned_existing_taggings = []
    tagged_existing = []

    with_temporary_staging_table(records) do |table_name|
      planned_rows, skipped, errors, planned_existing_taggings = build_import_plan(table_name, clinic_tag_id)
    end

    if clinic_tag_id.nil? && records.any?(&:clinic)
      records.each do |record|
        next unless record.clinic

        errors << {
          name: record.name,
          district: record.district,
          parent_facility_name: record.parent_facility_name,
          line_number: record.line_number,
          message: "Location tag '#{CLINIC_TAG_NAME}' was not found in location_tag table; clinic tagging was skipped"
        }
      end
    end

    ActiveRecord::Base.transaction do
      planned_rows.each do |row|
        record = row[:record]
        parent_location_id = row[:parent_location_id]

        if @dry_run
          created << {
            location_id: nil,
            name: record.name,
            district: record.district,
            parent_facility_name: record.parent_facility_name,
            parent_location_id: parent_location_id,
            tagged_village_clinic: record.clinic,
            line_number: record.line_number
          }
          next
        end

        location = create_location!(record, parent_location_id)

        if record.clinic
          LocationTagMap.find_or_create_by!(
            location_id: location.location_id,
            location_tag_id: clinic_tag_id
          )
        end

        created << {
          location_id: location.location_id,
          name: location.name,
          district: record.district,
          parent_facility_name: record.parent_facility_name,
          parent_location_id: parent_location_id,
          tagged_village_clinic: record.clinic,
          line_number: record.line_number
        }
      end

      planned_existing_taggings.each do |row|
        record = row[:record]
        location_id = row[:location_id]

        unless @dry_run
          LocationTagMap.find_or_create_by!(
            location_id: location_id,
            location_tag_id: clinic_tag_id
          )
        end

        tagged_existing << {
          location_id: location_id,
          name: record.name,
          district: record.district,
          parent_facility_name: record.parent_facility_name,
          line_number: record.line_number,
          tagged_village_clinic: true,
          status: @dry_run ? 'would_tag' : 'tagged'
        }
      end

      raise ActiveRecord::Rollback if @dry_run
    end

    manifest_path = nil
    unless @dry_run
      manifest_path = write_manifest!(
        input_path: @input_path,
        clinic_tag_id: clinic_tag_id,
        created: created,
        tagged_existing: tagged_existing,
        skipped: skipped,
        errors: errors
      )
    end

    print_apply_summary(created, tagged_existing, skipped, errors, manifest_path)
  end

  def revert
    manifest_path = resolve_manifest_path!
    manifest = JSON.parse(File.read(manifest_path))

    validate_manifest!(manifest)

    location_ids = Array(manifest['created_locations']).map { |row| row['location_id'] }.compact.uniq
    tagged_existing_location_ids = Array(manifest['tagged_existing_locations']).map do |row|
      row['location_id']
    end.compact.uniq
    clinic_tag_id = manifest['clinic_tag_id']

    if location_ids.empty? && tagged_existing_location_ids.empty?
      puts "No created locations recorded in manifest: #{manifest_path}"
      return
    end

    retired = []
    skipped = []
    untagged_existing = []

    ActiveRecord::Base.transaction do
      location_ids.each do |location_id|
        location = Location.unscoped.find_by(location_id: location_id)

        unless location
          skipped << { location_id: location_id, reason: 'not found' }
          next
        end

        if truthy_retired?(location.retired)
          skipped << { location_id: location_id, reason: 'already retired' }
          next
        end

        if @dry_run
          retired << { location_id: location_id, name: location.name }
          next
        end

        if clinic_tag_id
          LocationTagMap.where(location_id: location_id, location_tag_id: clinic_tag_id).delete_all
        end

        location.update!(
          retired: true,
          retired_by: @creator_id,
          date_retired: Time.current,
          retire_reason: "Retired by #{SCRIPT_ID} (run_id=#{manifest['run_id']})",
          changed_by: @creator_id,
          date_changed: Time.current
        )

        retired << { location_id: location_id, name: location.name }
      end

      tagged_existing_location_ids.each do |location_id|
        location = Location.unscoped.find_by(location_id: location_id)

        unless location
          skipped << { location_id: location_id, reason: 'tagged-existing location not found' }
          next
        end

        unless clinic_tag_id
          skipped << { location_id: location_id, reason: 'clinic tag id missing in manifest' }
          next
        end

        if @dry_run
          untagged_existing << { location_id: location_id, name: location.name }
          next
        end

        LocationTagMap.where(location_id: location_id, location_tag_id: clinic_tag_id).delete_all
        untagged_existing << { location_id: location_id, name: location.name }
      end

      raise ActiveRecord::Rollback if @dry_run
    end

    print_revert_summary(manifest_path, retired, untagged_existing, skipped)
  end

  def load_records
    rows = []

    CSV.foreach(@input_path, headers: true).with_index(2) do |row, line_number|
      name = row['name'].to_s.strip
      parent_facility_name = row['parent_facility'].to_s.strip
      clinic = parse_boolean(row['clinic'])
      district = row['district'].to_s.strip
      district = nil if district.empty?

      raise ArgumentError, "Line #{line_number}: name is required" if name.empty?
      raise ArgumentError, "Line #{line_number}: parent_facility is required" if parent_facility_name.empty?

      rows << Record.new(
        name: name,
        parent_facility_name: parent_facility_name,
        clinic: clinic,
        district: district,
        line_number: line_number
      )
    end

    rows
  rescue CSV::MalformedCSVError => e
    raise ArgumentError, "Invalid CSV format in #{@input_path}: #{e.message}"
  end

  def parse_boolean(raw)
    value = raw.to_s.strip.downcase
    return true if %w[1 true yes y].include?(value)

    false
  end

  def with_temporary_staging_table(records)
    connection = ActiveRecord::Base.connection
    table_name = "tmp_#{SCRIPT_ID}_#{SecureRandom.hex(6)}"
    quoted_table_name = connection.quote_table_name(table_name)

    connection.execute(<<~SQL.squish)
      CREATE TEMPORARY TABLE #{quoted_table_name} (
        csv_line_number INT NOT NULL,
        name VARCHAR(255) NOT NULL,
        parent_facility_name VARCHAR(255) NOT NULL,
        district VARCHAR(255) NULL,
        clinic TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY (csv_line_number)
      ) ENGINE=InnoDB
    SQL

    records.each_slice(500) do |batch|
      values = batch.map do |record|
        [
          record.line_number,
          connection.quote(record.name),
          connection.quote(record.parent_facility_name),
          connection.quote(record.district),
          (record.clinic ? 1 : 0)
        ]
      end

      sql_values = values.map { |v| "(#{v[0]}, #{v[1]}, #{v[2]}, #{v[3]}, #{v[4]})" }.join(', ')

      connection.execute(<<~SQL.squish)
        INSERT INTO #{quoted_table_name} (csv_line_number, name, parent_facility_name, district, clinic)
        VALUES #{sql_values}
      SQL
    end

    yield table_name
  ensure
    connection.execute("DROP TEMPORARY TABLE IF EXISTS #{quoted_table_name}") if connection && quoted_table_name
  end

  def build_import_plan(table_name, clinic_tag_id)
    connection = ActiveRecord::Base.connection
    quoted_table_name = connection.quote_table_name(table_name)
    staged_rows = connection.select_all(<<~SQL.squish).to_a
      SELECT csv_line_number, name, parent_facility_name, district, clinic
      FROM #{quoted_table_name}
      ORDER BY csv_line_number
    SQL

    planned_rows = []
    planned_existing_taggings = []
    skipped = []
    errors = []

    staged_rows.each do |row|
      record = staged_row_to_record(row)

      begin
        parent = resolve_parent!(record.parent_facility_name, record.district)
        existing = find_existing_location(record.name, parent.location_id)

        if existing
          existing_has_clinic_tag = clinic_tag_id && tagged_with_clinic?(existing.location_id, clinic_tag_id)
          needs_clinic_tag = record.clinic && !existing_has_clinic_tag

          skipped << {
            name: record.name,
            district: record.district,
            parent_facility_name: record.parent_facility_name,
            existing_location_id: existing.location_id,
            retired: retired_value(existing),
            line_number: record.line_number,
            clinic_requested: record.clinic,
            clinic_tag_present: !!existing_has_clinic_tag,
            clinic_tag_missing: needs_clinic_tag
          }

          if needs_clinic_tag
            planned_existing_taggings << {
              record: record,
              location_id: existing.location_id
            }
          end

          next
        end

        planned_rows << {
          record: record,
          parent_location_id: parent.location_id
        }
      rescue StandardError => e
        errors << {
          name: record.name,
          district: record.district,
          parent_facility_name: record.parent_facility_name,
          line_number: record.line_number,
          message: e.message
        }
      end
    end

    duplicate_errors, duplicate_line_numbers = duplicate_plan_errors(planned_rows)
    errors.concat(duplicate_errors)
    planned_rows.reject! do |row|
      duplicate_line_numbers.include?(row[:record].line_number)
    end

    [planned_rows, skipped, errors, planned_existing_taggings]
  end

  def tagged_with_clinic?(location_id, clinic_tag_id)
    LocationTagMap.where(location_id: location_id, location_tag_id: clinic_tag_id).exists?
  end

  def duplicate_plan_errors(planned_rows)
    grouped = planned_rows.group_by do |row|
      [row[:parent_location_id], row[:record].name.to_s.strip.downcase]
    end

    duplicate_errors = []
    duplicate_line_numbers = []

    grouped.each_value do |rows|
      next if rows.size < 2

      line_numbers = rows.map { |row| row[:record].line_number }.sort
      message = "Duplicate staged location under same parent (CSV lines: #{line_numbers.join(', ')})"

      rows.each do |row|
        record = row[:record]
        duplicate_line_numbers << record.line_number
        duplicate_errors << {
          name: record.name,
          district: record.district,
          parent_facility_name: record.parent_facility_name,
          line_number: record.line_number,
          message: message
        }
      end
    end

    [duplicate_errors, duplicate_line_numbers.uniq]
  end

  def staged_row_to_record(row)
    Record.new(
      name: row['name'],
      parent_facility_name: row['parent_facility_name'],
      clinic: row['clinic'].to_i == 1,
      district: row['district'].presence,
      line_number: row['csv_line_number'].to_i
    )
  end

  def clinic_tag_id_if_needed(records)
    return nil unless records.any?(&:clinic)

    tag = LocationTag.unscoped.find_by(name: CLINIC_TAG_NAME)
    return nil unless tag

    tag.location_tag_id
  end

  def resolve_parent!(parent_name, district = nil)
    matches = Location.unscoped
                      .where(retired: [false, 0, nil])
                      .where('LOWER(TRIM(name)) = LOWER(TRIM(?))', parent_name)
                      .to_a

    if district && matches.size > 1
      district_name = district.downcase.strip
      matches = matches.select do |location|
        values = [location.county_district, location.city_village, location.state_province]
        values.compact.any? { |value| value.to_s.strip.downcase == district_name }
      end
    end

    if matches.empty?
      if district
        raise "Parent facility '#{parent_name}' was not found for district '#{district}'"
      end

      raise "Parent facility '#{parent_name}' was not found"
    end

    if matches.size > 1
      if district
        raise "Parent facility '#{parent_name}' is ambiguous in district '#{district}' (#{matches.size} matches)"
      end

      raise "Parent facility '#{parent_name}' is ambiguous (#{matches.size} matches)"
    end

    matches.first
  end

  def find_existing_location(name, parent_location_id)
    Location.unscoped
            .where(parent_location: parent_location_id)
            .where('LOWER(TRIM(name)) = LOWER(TRIM(?))', name)
            .order(:location_id)
            .first
  end

  def create_location!(record, parent_location_id)
    now = Time.current

    Location.unscoped.create!(
      name: record.name,
      parent_location: parent_location_id,
      creator: @creator_id,
      date_created: now,
      changed_by: @creator_id,
      date_changed: now,
      uuid: SecureRandom.uuid,
      retired: false
    )
  end

  def write_manifest!(input_path:, clinic_tag_id:, created:, tagged_existing:, skipped:, errors:)
    FileUtils.mkdir_p(MANIFEST_DIR)

    run_id = Time.now.utc.strftime('%Y%m%d%H%M%S')
    manifest_path = File.join(MANIFEST_DIR, "#{SCRIPT_ID}_#{run_id}.json")
    manifest = {
      script: SCRIPT_ID,
      run_id: run_id,
      created_at_utc: Time.now.utc.iso8601,
      input_path: input_path,
      creator_id: @creator_id,
      clinic_tag_id: clinic_tag_id,
      created_locations: created,
      tagged_existing_locations: tagged_existing,
      skipped_locations: skipped,
      errors: errors
    }

    File.write(manifest_path, JSON.pretty_generate(manifest))
    File.write(LATEST_MANIFEST_POINTER, JSON.pretty_generate({ manifest_path: manifest_path }))

    manifest_path
  end

  def resolve_manifest_path!
    return @manifest_path if @manifest_path && File.exist?(@manifest_path)

    if File.exist?(LATEST_MANIFEST_POINTER)
      latest = JSON.parse(File.read(LATEST_MANIFEST_POINTER))
      path = latest['manifest_path']
      return path if path && File.exist?(path)
    end

    candidates = Dir.glob(File.join(MANIFEST_DIR, "#{SCRIPT_ID}_*.json")).sort
    raise 'No manifest found. Provide --manifest PATH or run apply first.' if candidates.empty?

    candidates.last
  end

  def validate_manifest!(manifest)
    return if manifest['script'] == SCRIPT_ID

    raise "Manifest script mismatch. Expected '#{SCRIPT_ID}', got '#{manifest['script']}'"
  end

  def assert_input_file_exists!
    return if File.exist?(@input_path)

    raise "Input file not found: #{@input_path}"
  end

  def print_apply_summary(created, tagged_existing, skipped, errors, manifest_path)
    puts 'Location import summary:'
    puts "  Mode: #{@dry_run ? 'dry-run' : 'apply'}"
    puts "  Input: #{@input_path}"
    puts "  Created: #{created.size}"
    puts "  Existing tagged: #{tagged_existing.size}"
    puts "  Skipped existing: #{skipped.size}"
    puts "  Errors: #{errors.size}"
    puts "  Manifest: #{manifest_path}" if manifest_path

    skipped.each do |row|
      clinic_status = if row[:clinic_requested]
                        row[:clinic_tag_missing] ? 'missing->will-tag' : 'already-tagged'
                      else
                        'not-requested'
                      end

      puts "  SKIPPED line=#{row[:line_number]} district='#{row[:district]}' name='#{row[:name]}' parent='#{row[:parent_facility_name]}' existing_location_id=#{row[:existing_location_id]} retired=#{row[:retired]} clinic_tag=#{clinic_status}"
    end

    tagged_existing.each do |row|
      puts "  TAGGED_EXISTING line=#{row[:line_number]} district='#{row[:district]}' name='#{row[:name]}' parent='#{row[:parent_facility_name]}' location_id=#{row[:location_id]} status='#{row[:status]}'"
    end

    errors.each do |row|
      puts "  ERROR line=#{row[:line_number]} district='#{row[:district]}' name='#{row[:name]}' parent='#{row[:parent_facility_name]}' message='#{row[:message]}'"
    end

    unless @dry_run
      created_location_ids = created.map { |row| row[:location_id] }.compact
      display_created_locations_with_tags(created_location_ids)
    end
  end

  def print_revert_summary(manifest_path, retired, untagged_existing, skipped)
    puts 'Location revert summary:'
    puts "  Mode: #{@dry_run ? 'dry-run' : 'revert'}"
    puts "  Manifest: #{manifest_path}"
    puts "  Retired: #{retired.size}"
    puts "  Existing untagged: #{untagged_existing.size}"
    puts "  Skipped: #{skipped.size}"

    skipped.each do |row|
      puts "  SKIPPED location_id=#{row[:location_id]} reason='#{row[:reason]}'"
    end

    unless @dry_run
      retired_location_ids = retired.map { |row| row[:location_id] }.compact
      display_retired_locations_with_tags(retired_location_ids)
    end
  end

  def retired_value(location)
    truthy_retired?(location.retired)
  end

  def display_created_locations_with_tags(created_location_ids)
    return if created_location_ids.empty?

    puts "\n--- Live Query: Created Locations with Tags ---"

    locations_with_tags = Location.unscoped
                                   .where(location_id: created_location_ids)
                                   .joins("LEFT OUTER JOIN location_tag_map ltm ON location.location_id = ltm.location_id")
                                   .joins("LEFT OUTER JOIN location_tag lt ON ltm.location_tag_id = lt.location_tag_id")
                                   .select("location.location_id, location.name, location.parent_location, lt.name as tag_name")
                                   .order("location.location_id")

    locations_with_tags.each do |loc|
      tag_display = loc.tag_name.present? ? loc.tag_name : "(no tags)"
      puts "  ID: #{loc.location_id.to_s.rjust(4)} | Name: #{loc.name.ljust(30)} | Tag: #{tag_display}"
    end

    puts "--- End of Query Results ---\n"
  end

  def display_retired_locations_with_tags(retired_location_ids)
    return if retired_location_ids.empty?

    puts "\n--- Live Query: Retired Locations ---"

    locations = Location.unscoped
                        .where(location_id: retired_location_ids)
                        .select("location_id, name, retired, retired_by, date_retired")
                        .order("location_id")

    locations.each do |loc|
      retired_at = loc.date_retired.strftime('%Y-%m-%d %H:%M:%S') if loc.date_retired.present?
      puts "  ID: #{loc.location_id.to_s.rjust(4)} | Name: #{loc.name.ljust(30)} | Retired By: #{loc.retired_by} | Date: #{retired_at}"
    end

    puts "--- End of Query Results ---\n"
  end

  def truthy_retired?(value)
    [true, 1, '1'].include?(value)
  end

end

def parse_options(argv)
  options = {
    input_path: LocationBulkAdd::DEFAULT_INPUT_PATH,
    manifest_path: nil,
    creator_id: 1,
    dry_run: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = <<~USAGE
      Usage:
        bin/location_bulk_add.rb apply [options]
        bin/location_bulk_add.rb revert [options]

      Options:
    USAGE

    opts.on('--input PATH', 'CSV file with headers: name,parent_facility,clinic[,district]') do |value|
      options[:input_path] = value
    end

    opts.on('--manifest PATH', 'Manifest path to use for revert (defaults to latest)') do |value|
      options[:manifest_path] = value
    end

    opts.on('--creator ID', Integer, 'Creator and changed_by user id (default: 1)') do |value|
      options[:creator_id] = value
    end

    opts.on('--dry-run', 'Preview actions without changing the database') do
      options[:dry_run] = true
    end

    opts.on('-h', '--help', 'Show help') do
      puts opts
      exit 0
    end
  end

  parser.parse!(argv)
  command = argv.shift

  unless %w[apply revert].include?(command)
    puts parser
    raise ArgumentError, "Command must be one of: apply, revert"
  end

  [command, options]
end

begin
  command, options = parse_options(ARGV)

  LocationBulkAdd.new(
    command: command,
    input_path: options[:input_path],
    manifest_path: options[:manifest_path],
    creator_id: options[:creator_id],
    dry_run: options[:dry_run]
  ).run
rescue StandardError => e
  warn "Error: #{e.message}"
  exit 1
end