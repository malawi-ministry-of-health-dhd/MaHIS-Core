# frozen_string_literal: true

require 'csv'
require 'fileutils'

# Reviews and repairs three identifier anomalies:
# - one identifier value owned by different active patients;
# - multiple different values of one type on the same patient;
# - repeated identical identifier rows on the same patient.
class DuplicateIdentifierCleanupTask
  CONFIRMATION = 'REPAIR_REVIEWED_IDENTIFIER_DUPLICATES'
  DDE_CONFIRMATION = 'REQUEST_FRESH_DDE_IDENTIFIERS'
  UNATTENDED_CONFIRMATION = 'REPAIR_ALL_SUPPORTED_IDENTIFIER_DUPLICATES_WITHOUT_REVIEW'
  DEFAULT_DATABASE = 'NDC_mahis'
  DEFAULT_LIMIT = 25
  MAX_LIMIT = 500
  EXCLUDED_IDENTIFIER_TYPES = [4, 31].freeze
  DDE_NPID_TYPE = 3
  DDE_DOC_TYPE = 27
  OLD_NPID_TYPE = 2
  DDE_PURGED_TYPES = [DDE_NPID_TYPE, DDE_DOC_TYPE, OLD_NPID_TYPE].freeze
  TRUTHY = %w[1 true yes y].freeze
  HEADERS = %w[
    approved collision_kind action identifier_type identifier_type_name
    current_identifier keeper_patient_id target_patient_id
    keeper_identifier_row_id target_identifier_row_id replacement_identifier note
  ].freeze

  def initialize(env = ENV)
    @apply = truthy?(env['APPLY'])
    @unattended = truthy?(env['UNATTENDED'])
    @unattended_confirmation = env['UNATTENDED_CONFIRM'].to_s
    @database_name = env.fetch('DB_NAME', DEFAULT_DATABASE).to_s
    @confirmation = env['CONFIRM'].to_s
    @dde_confirmation = env['DDE_CONFIRM'].to_s
    @operator_user_id = env['USER_ID'].to_i
    @approval_path = expanded_path(env['APPROVAL_FILE']) if env['APPROVAL_FILE'].present?
    @output_path = expanded_path(env['OUTPUT'].presence || Rails.root.join('tmp', 'duplicate_identifier_review.csv'))
    @limit = [[env.fetch('LIMIT', DEFAULT_LIMIT).to_i, 1].max, MAX_LIMIT].min
    validate_options!
  end

  def run
    validate_target_database!
    @apply ? apply_approved_rows : export_review
  end

  private

  def validate_options!
    return unless @apply

    raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required" unless @confirmation == CONFIRMATION
    if @unattended
      unless @unattended_confirmation == UNATTENDED_CONFIRMATION
        raise ArgumentError, "UNATTENDED_CONFIRM=#{UNATTENDED_CONFIRMATION} is required"
      end
    else
      raise ArgumentError, 'APPROVAL_FILE is required' if @approval_path.blank?
      raise ArgumentError, "Approval file not found: #{@approval_path}" unless File.file?(@approval_path)
    end
    raise ArgumentError, 'USER_ID is required' unless @operator_user_id.positive?
  end

  def validate_target_database!
    actual = connection.select_value('SELECT DATABASE()').to_s
    return if actual.casecmp?(@database_name)

    raise "Connected database is #{actual.inspect}; expected #{@database_name.inspect}"
  end

  def export_review
    rows = cross_patient_rows + multiple_value_rows + repeated_row_rows
    FileUtils.mkdir_p(File.dirname(@output_path))
    CSV.open(@output_path, 'w', write_headers: true, headers: HEADERS) do |csv|
      rows.each { |row| csv << HEADERS.map { |header| row[header] } }
    end
    File.chmod(0o600, @output_path)

    puts "\n===== Duplicate Identifier Review ====="
    puts "Cross-patient reassignments: #{rows.count { |row| row['collision_kind'] == 'cross_patient' }}"
    puts "Extra different values on one patient: #{rows.count { |row| row['collision_kind'] == 'multiple_values' }}"
    puts "Repeated identical rows: #{rows.count { |row| row['collision_kind'] == 'repeated_row' }}"
    puts "Review CSV: #{@output_path}"
    puts 'No identifiers changed. Run this after completing exact-patient merges.'
    puts "Apply reviewed rows with: APPLY=1 CONFIRM=#{CONFIRMATION} USER_ID=<id> " \
         "APPROVAL_FILE=#{@output_path} LIMIT=#{DEFAULT_LIMIT} bin/rails identifiers:cleanup_duplicates"
    puts "Include DDE_CONFIRM=#{DDE_CONFIRMATION} when approved rows request fresh type-3 identifiers."
  end

  def apply_approved_rows
    return apply_all_supported_rows if @unattended

    rows = CSV.read(@approval_path, headers: true).select { |row| truthy?(row['approved']) }.first(@limit)
    raise 'The approval file has no rows marked approved=yes' if rows.empty?

    with_operator_context { apply_rows!(rows) }
  end

  def apply_all_supported_rows
    total = 0

    loop do
      candidates = cross_patient_rows + multiple_value_rows + repeated_row_rows
      supported = unattended_batch(candidates)
      break if supported.empty?

      with_operator_context { apply_rows!(supported) }
      total += supported.length
      puts "Completed unattended identifier batch: #{total} supported repair(s) applied"
    end

    unresolved = (cross_patient_rows + multiple_value_rows + repeated_row_rows)
                 .select { |row| row['action'] == 'assign_reviewed_value' }
    puts "\nCompleted all #{total} supported unattended identifier repair(s)."
    if unresolved.any?
      puts "#{unresolved.length} shared non-DDE identifier row(s) remain because their identifier types have no automatic number source."
      puts 'ARV and NCD identifiers were excluded and were not changed.'
    else
      puts 'No supported duplicate identifiers remain. ARV and NCD identifiers were excluded.'
    end
  end

  def unattended_batch(candidates)
    supported = candidates.reject { |row| row['action'] == 'assign_reviewed_value' }
    dde_patients = {}

    supported.select do |row|
      patient_id = row['target_patient_id'].to_i
      if row['action'] == 'request_fresh_dde'
        next false if dde_patients[patient_id]

        dde_patients[patient_id] = true
        next true
      end

      !(dde_patients[patient_id] && DDE_PURGED_TYPES.include?(row['identifier_type'].to_i))
    end.first(@limit)
  end

  def apply_rows!(rows)
    rows.each_with_index do |row, index|
      apply_row!(row)
      puts "Applied #{index + 1}/#{rows.length}: #{row['action']} for patient #{row['target_patient_id']}"
    end
  end

  def with_operator_context
    operator = User.unscoped.find(@operator_user_id)
    previous_user = User.current
    previous_location = Location.current
    User.current = operator
    Location.current = Location.unscoped.find_by(location_id: operator.location_id) || previous_location

    yield
  ensure
    User.current = previous_user if defined?(previous_user)
    Location.current = previous_location if defined?(previous_location)
  end

  def apply_row!(row)
    target_row = PatientIdentifier.find_by(patient_identifier_id: row['target_identifier_row_id'].to_i)
    raise "Identifier row #{row['target_identifier_row_id']} is missing or inactive" unless target_row
    unless target_row.patient_id == row['target_patient_id'].to_i &&
           target_row.identifier_type == row['identifier_type'].to_i &&
           normalize(target_row.identifier) == normalize(row['current_identifier'])
      raise "Identifier row #{target_row.id} changed after review; regenerate the CSV"
    end

    case row['action']
    when 'delete_extra_identifier'
      delete_identifier_row!(target_row)
    when 'request_fresh_dde'
      request_fresh_dde!(target_row.patient)
    when 'assign_reviewed_value'
      replace_with_reviewed_value!(target_row, row['replacement_identifier'])
    else
      raise "Unsupported action #{row['action'].inspect}"
    end
  end

  def replace_with_reviewed_value!(old_row, replacement)
    raise 'replacement_identifier is required for this identifier type' if replacement.to_s.strip.empty?

    assign_and_purge!(old_row, replacement.to_s.strip)
  end

  def assign_and_purge!(old_row, replacement, legacy_type: nil)
    patient_id = old_row.patient_id
    type = old_row.identifier_type
    location_id = old_row.location_id || Location.current&.id
    created = PatientIdentifierService.create(
      patient_id:,
      identifier: replacement,
      identifier_type: type,
      location_id:
    )
    raise "Failed to assign #{replacement} to patient #{patient_id}" unless created&.persisted?

    PatientIdentifier.unscoped.where(patient_id:, identifier_type: type)
                     .where.not(patient_identifier_id: created.id).delete_all
    PatientIdentifier.unscoped.where(patient_id:, identifier_type: legacy_type).delete_all if legacy_type
  end

  def request_fresh_dde!(patient)
    unless @dde_confirmation == DDE_CONFIRMATION
      raise "DDE_CONFIRM=#{DDE_CONFIRMATION} is required for type-3 reassignment"
    end

    doc_type = PatientIdentifierType.find(DDE_DOC_TYPE)
    doc_id = PatientIdentifier.find_by(patient:, type: doc_type)&.identifier
    if doc_id.present? && PatientIdentifier.where(type: doc_type, identifier: doc_id).where.not(patient_id: patient.id).exists?
      raise "Patient #{patient.id} shares DDE document ID #{doc_id}; automatic remote reassignment is unsafe"
    end

    program = patient.patient_programs.order(:date_enrolled).first&.program || Program.find(14)
    service = DdeService.new(program:)
    if doc_id.present?
      service.reassign_patient_npid('patient_id' => patient.id, 'doc_id' => doc_id)
    else
      service.create_patient(patient, nil)
    end

    current_npid = PatientIdentifier.where(patient_id: patient.id, identifier_type: DDE_NPID_TYPE)
                                    .order(date_created: :desc).first
    raise "DDE did not assign a new type-3 identifier to patient #{patient.id}" unless current_npid

    PatientIdentifier.unscoped.where(patient_id: patient.id, identifier_type: DDE_NPID_TYPE)
                     .where.not(patient_identifier_id: current_npid.id).delete_all
    current_doc = PatientIdentifier.where(patient_id: patient.id, identifier_type: DDE_DOC_TYPE)
                                   .order(date_created: :desc).first
    PatientIdentifier.unscoped.where(patient_id: patient.id, identifier_type: DDE_DOC_TYPE)
                     .where.not(patient_identifier_id: current_doc&.id).delete_all
    PatientIdentifier.unscoped.where(patient_id: patient.id, identifier_type: OLD_NPID_TYPE).delete_all
  end

  def delete_identifier_row!(row)
    deleted = PatientIdentifier.unscoped.where(patient_identifier_id: row.id).delete_all
    raise "Identifier row #{row.id} was not deleted" unless deleted == 1
  end

  def cross_patient_rows
    rows = connection.select_all(<<~SQL).to_a
      WITH active_rows AS (
        SELECT pi.*, UPPER(TRIM(pi.identifier)) AS normalized_identifier,
               ROW_NUMBER() OVER (
                 PARTITION BY pi.identifier_type, UPPER(TRIM(pi.identifier)), pi.patient_id
                 ORDER BY pi.date_created, pi.patient_identifier_id
               ) AS patient_value_rank
        FROM patient_identifier pi
        INNER JOIN patient p ON p.patient_id = pi.patient_id AND p.voided = 0
        INNER JOIN person pe ON pe.person_id = pi.patient_id AND pe.voided = 0
        WHERE pi.voided = 0
          AND pi.identifier_type NOT IN (#{EXCLUDED_IDENTIFIER_TYPES.join(', ')})
          AND NULLIF(TRIM(pi.identifier), '') IS NOT NULL
      ), owners AS (
        SELECT active_rows.*,
               FIRST_VALUE(patient_id) OVER owner_window AS keeper_patient_id,
               FIRST_VALUE(patient_identifier_id) OVER owner_window AS keeper_identifier_row_id,
               ROW_NUMBER() OVER owner_window AS owner_rank,
               COUNT(*) OVER owner_partition AS owner_count
        FROM active_rows
        WHERE patient_value_rank = 1
        WINDOW
          owner_partition AS (PARTITION BY identifier_type, normalized_identifier),
          owner_window AS (
            PARTITION BY identifier_type, normalized_identifier
            ORDER BY date_created, patient_identifier_id
          )
      )
      SELECT owners.identifier_type, pit.name AS identifier_type_name,
             owners.identifier AS current_identifier,
             owners.keeper_patient_id, owners.patient_id AS target_patient_id,
             owners.keeper_identifier_row_id,
             owners.patient_identifier_id AS target_identifier_row_id
      FROM owners
      LEFT JOIN patient_identifier_type pit
        ON pit.patient_identifier_type_id = owners.identifier_type
      WHERE owners.owner_count > 1 AND owners.owner_rank > 1
    SQL

    rows.map do |row|
      type = row['identifier_type'].to_i
      action = case type
               when DDE_NPID_TYPE then 'request_fresh_dde'
               else 'assign_reviewed_value'
               end
      review_row(row.merge('collision_kind' => 'cross_patient', 'action' => action))
    end
  end

  def multiple_value_rows
    rows = connection.select_all(<<~SQL).to_a
      WITH active_rows AS (
        SELECT pi.*, UPPER(TRIM(pi.identifier)) AS normalized_identifier,
               ROW_NUMBER() OVER (
                 PARTITION BY pi.patient_id, pi.identifier_type, UPPER(TRIM(pi.identifier))
                 ORDER BY pi.date_created, pi.patient_identifier_id
               ) AS value_row_rank
        FROM patient_identifier pi
        INNER JOIN patient p ON p.patient_id = pi.patient_id AND p.voided = 0
        WHERE pi.voided = 0
          AND pi.identifier_type NOT IN (#{EXCLUDED_IDENTIFIER_TYPES.join(', ')})
          AND NULLIF(TRIM(pi.identifier), '') IS NOT NULL
      ), distinct_values AS (
        SELECT active_rows.*,
               FIRST_VALUE(patient_identifier_id) OVER value_window AS keeper_identifier_row_id,
               ROW_NUMBER() OVER value_window AS value_rank,
               COUNT(*) OVER value_partition AS value_count
        FROM active_rows
        WHERE value_row_rank = 1
        WINDOW
          value_partition AS (PARTITION BY patient_id, identifier_type),
          value_window AS (
            PARTITION BY patient_id, identifier_type
            ORDER BY date_created, patient_identifier_id
          )
      )
      SELECT distinct_values.identifier_type, pit.name AS identifier_type_name,
             distinct_values.identifier AS current_identifier,
             distinct_values.patient_id AS keeper_patient_id,
             distinct_values.patient_id AS target_patient_id,
             distinct_values.keeper_identifier_row_id,
             distinct_values.patient_identifier_id AS target_identifier_row_id
      FROM distinct_values
      LEFT JOIN patient_identifier_type pit
        ON pit.patient_identifier_type_id = distinct_values.identifier_type
      WHERE distinct_values.value_count > 1 AND distinct_values.value_rank > 1
    SQL

    rows.map do |row|
      review_row(row.merge('collision_kind' => 'multiple_values', 'action' => 'delete_extra_identifier'))
    end
  end

  def repeated_row_rows
    rows = connection.select_all(<<~SQL).to_a
      WITH ranked AS (
        SELECT pi.*,
               FIRST_VALUE(patient_identifier_id) OVER duplicate_window AS keeper_identifier_row_id,
               ROW_NUMBER() OVER duplicate_window AS duplicate_rank,
               COUNT(*) OVER duplicate_partition AS duplicate_count
        FROM patient_identifier pi
        INNER JOIN patient p ON p.patient_id = pi.patient_id AND p.voided = 0
        WHERE pi.voided = 0
          AND pi.identifier_type NOT IN (#{EXCLUDED_IDENTIFIER_TYPES.join(', ')})
          AND NULLIF(TRIM(pi.identifier), '') IS NOT NULL
        WINDOW
          duplicate_partition AS (
            PARTITION BY pi.patient_id, pi.identifier_type, UPPER(TRIM(pi.identifier))
          ),
          duplicate_window AS (
            PARTITION BY pi.patient_id, pi.identifier_type, UPPER(TRIM(pi.identifier))
            ORDER BY pi.date_created, pi.patient_identifier_id
          )
      )
      SELECT ranked.identifier_type, pit.name AS identifier_type_name,
             ranked.identifier AS current_identifier,
             ranked.patient_id AS keeper_patient_id,
             ranked.patient_id AS target_patient_id,
             ranked.keeper_identifier_row_id,
             ranked.patient_identifier_id AS target_identifier_row_id
      FROM ranked
      LEFT JOIN patient_identifier_type pit
        ON pit.patient_identifier_type_id = ranked.identifier_type
      WHERE ranked.duplicate_count > 1 AND ranked.duplicate_rank > 1
    SQL

    rows.map do |row|
      review_row(row.merge('collision_kind' => 'repeated_row', 'action' => 'delete_extra_identifier'))
    end
  end

  def review_row(row)
    HEADERS.to_h { |header| [header, row[header]] }.merge('approved' => '', 'replacement_identifier' => '', 'note' => '')
  end

  def normalize(value)
    value.to_s.strip.upcase
  end

  def truthy?(value)
    TRUTHY.include?(value.to_s.strip.downcase)
  end

  def expanded_path(path)
    File.expand_path(path.to_s, Rails.root)
  end

  def connection
    ActiveRecord::Base.connection
  end
end
