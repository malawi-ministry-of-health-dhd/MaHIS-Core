# frozen_string_literal: true

require 'csv'
require 'fileutils'

# Reviews and repairs three identifier anomalies:
# - one identifier value owned by different active patients;
# - multiple different values of one type on the same patient;
# - repeated identical identifier rows on the same patient.
class DuplicateIdentifierCleanupTask
  class DeferredDdeRepair < StandardError; end

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
  MULTIPLE_VALUE_EXCLUDED_IDENTIFIER_TYPES = (EXCLUDED_IDENTIFIER_TYPES + [OLD_NPID_TYPE]).freeze
  TRUTHY = %w[1 true yes y].freeze
  HEADERS = %w[
    approved collision_kind action identifier_type identifier_type_name
    current_identifier keeper_patient_id target_patient_id
    keeper_identifier_row_id target_identifier_row_id replacement_identifier note
  ].freeze
  DEFERRED_HEADERS = (HEADERS + ['deferred_reason']).freeze

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
    @deferred_path = expanded_path(
      env['DEFERRED_OUTPUT'].presence || Rails.root.join('tmp', 'deferred_identifier_repairs.csv')
    )
    @deferred_rows = {}
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

    begin
      loop do
        candidates = cross_patient_rows + multiple_value_rows + repeated_row_rows
        supported = unattended_batch(candidates)
        break if supported.empty?

        applied = with_operator_context { apply_rows!(supported) }
        total += applied
        puts "Completed unattended identifier batch: #{total} supported repair(s) applied"
      end
    ensure
      # Keep the report accurate even if a later, unrelated repair aborts the
      # task after some DDE rows have already been deferred.
      write_deferred_report!
    end

    unresolved = (cross_patient_rows + multiple_value_rows + repeated_row_rows)
                 .select { |row| row['action'] == 'assign_reviewed_value' }
    puts "\nCompleted all #{total} supported unattended identifier repair(s)."
    if @deferred_rows.any?
      puts "Deferred #{@deferred_rows.length} DDE repair(s); their local identifiers were left unchanged."
      puts "Deferred report: #{@deferred_path}"
    end
    if unresolved.any?
      puts "#{unresolved.length} shared non-DDE identifier row(s) remain because their identifier types have no automatic number source."
      puts 'ARV and NCD identifiers were excluded and were not changed.'
    elsif @deferred_rows.any?
      puts 'No other supported duplicate identifiers remain. ARV and NCD identifiers were excluded.'
    else
      puts 'No supported duplicate identifiers remain. ARV and NCD identifiers were excluded.'
    end
  end

  def unattended_batch(candidates)
    supported = candidates.reject do |row|
      row['action'] == 'assign_reviewed_value' || @deferred_rows.key?(deferred_row_key(row))
    end
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
    applied = 0
    rows.each_with_index do |row, index|
      begin
        apply_row!(row)
        applied += 1
        puts "Applied #{index + 1}/#{rows.length}: #{row['action']} for patient #{row['target_patient_id']}"
      rescue DeferredDdeRepair => e
        raise unless @unattended

        remember_deferred_row(row, e.message)
        puts "Deferred #{index + 1}/#{rows.length}: #{row['action']} for patient " \
             "#{row['target_patient_id']} — #{e.message}"
      end
    end
    applied
  end

  def remember_deferred_row(row, reason)
    values = HEADERS.to_h { |header| [header, row[header]] }
    @deferred_rows[deferred_row_key(row)] = values.merge('deferred_reason' => reason)
  end

  def deferred_row_key(row)
    [row['action'].to_s, row['target_identifier_row_id'].to_i]
  end

  def write_deferred_report!
    FileUtils.mkdir_p(File.dirname(@deferred_path))
    CSV.open(@deferred_path, 'w', write_headers: true, headers: DEFERRED_HEADERS) do |csv|
      @deferred_rows.each_value do |row|
        csv << DEFERRED_HEADERS.map { |header| row[header] }
      end
    end
    File.chmod(0o600, @deferred_path)
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

    doc_id = current_dde_document_id(patient.id)
    shared_owners = shared_dde_document_owners(doc_id)
    if shared_owners.many?
      lookup_service = DdeService.new(program: dde_program_for(patient))
      patient = shared_document_repair_target!(lookup_service, patient, doc_id, owners: shared_owners)
      doc_id = current_dde_document_id(patient.id)
    end

    previous_identifiers = active_dde_identifier_snapshots(patient.id)
    previous_npids = previous_identifiers.select { |identifier| identifier[:identifier_type] == DDE_NPID_TYPE }
    service = DdeService.new(program: dde_program_for(patient))
    begin
      PatientIdentifier.transaction do
        if shared_owners.many?
          # Two nonmatching local patients cannot safely reassign the same remote
          # DDE person: doing so would also change the keeper's identity. Detach
          # only the demographically nonmatching target and give it a separate
          # remote person UUID and NPID.
          puts "Patient #{patient.id} shares DDE document ID #{doc_id}; registering a separate DDE person"
          provision_separate_dde_identity!(service, patient, excluding_doc_id: doc_id)
        elsif doc_id.present?
          begin
            service.reassign_patient_npid('patient_id' => patient.id, 'doc_id' => doc_id)
          rescue DdeService::MissingRemotePatientError
            # This patient is a non-keeper in a duplicated-NPID group. The
            # selected keeper retains the shared NPID; a stale UUID that this
            # proxy cannot resolve is discarded locally and replaced with an
            # independent DDE person UUID and NPID.
            puts "Patient #{patient.id} DDE document #{doc_id} is missing locally; " \
                 'registering a separate DDE person'
            provision_separate_dde_identity!(service, patient, excluding_doc_id: doc_id)
          end
        else
          service.create_patient(patient, nil)
        end

        current_npid = PatientIdentifier.where(patient_id: patient.id, identifier_type: DDE_NPID_TYPE)
                                        .order(date_created: :desc, patient_identifier_id: :desc).first
        raise "DDE did not assign a new type-3 identifier to patient #{patient.id}" unless current_npid
        if previous_npids.any? { |identifier| normalize(identifier[:identifier]) == normalize(current_npid.identifier) }
          raise "DDE returned existing NPID #{current_npid.identifier} for patient #{patient.id}; duplicate was not repaired"
        end

        consolidate_dde_identifiers!(patient.id, current_npid, previous_identifiers)
      end
    rescue UnprocessableEntityError => e
      raise DeferredDdeRepair,
            "DDE rejected patient #{patient.id}: #{e.message}; local identifiers were left unchanged"
    end
  end

  def current_dde_document_id(patient_id)
    PatientIdentifier.where(patient_id:, identifier_type: DDE_DOC_TYPE)
                     .order(date_created: :desc, patient_identifier_id: :desc)
                     .first&.identifier
  end

  def dde_program_for(patient)
    patient.patient_programs.order(:date_enrolled).first&.program || Program.find(14)
  end

  def shared_dde_document_owners(doc_id)
    return [] if doc_id.blank?

    patient_ids = PatientIdentifier.where(identifier_type: DDE_DOC_TYPE)
                                   .where('UPPER(TRIM(identifier)) = ?', normalize(doc_id))
                                   .distinct
                                   .pluck(:patient_id)
    Patient.where(patient_id: patient_ids)
           .includes(person: %i[names addresses])
           .select { |owner| owner.person.present? }
           .sort_by(&:id)
  end

  def shared_document_repair_target!(service, requested_patient, doc_id, owners:)
    remote_matches = service.find_remote_matches_by_doc_id(doc_id)
    if remote_matches.empty?
      raise DeferredDdeRepair,
            "shared DDE document #{doc_id} is not in the local proxy; keeper is unknown pending master sync"
    end
    if remote_matches.many?
      raise DeferredDdeRepair,
            "shared DDE document #{doc_id} returned multiple local-proxy records; no patient was changed"
    end

    remote = remote_matches.first
    keepers = owners.select { |owner| exact_remote_demographics?(owner, remote) }
    unless keepers.one?
      raise DeferredDdeRepair,
            "shared DDE document #{doc_id} matched #{keepers.length} local patient(s); exactly one keeper is required"
    end

    keeper = keepers.first
    return requested_patient unless keeper.id == requested_patient.id

    target = owners.reject { |owner| owner.id == keeper.id }.min_by(&:id)
    unless target
      raise DeferredDdeRepair, "shared DDE document #{doc_id} has no non-keeper patient to repair"
    end

    puts "Patient #{requested_patient.id} matches shared DDE document #{doc_id}; " \
         "keeping it and repairing nonmatching patient #{target.id} instead"
    target
  end

  def detach_shared_dde_identity!(patient_id)
    PatientIdentifier.unscoped
                     .where(patient_id:, identifier_type: [DDE_NPID_TYPE, DDE_DOC_TYPE])
                     .delete_all
  end

  def provision_separate_dde_identity!(service, patient, excluding_doc_id:)
    reusable_remote = reusable_remote_dde_person(service, patient, excluding_doc_id:)
    detach_shared_dde_identity!(patient.id)
    if reusable_remote
      puts "Reusing unlinked DDE person #{reusable_remote['doc_id']} with NPID #{reusable_remote['npid']}"
      service.link_local_patient_to_remote(patient.reload, reusable_remote)
    else
      service.create_patient(patient.reload, nil)
    end
  end

  def reusable_remote_dde_person(service, patient, excluding_doc_id:)
    matches = service.find_remote_demographic_matches(patient).select do |remote|
      remote_doc_id = remote['doc_id'].to_s.strip
      remote_doc_id.present? &&
        normalize(remote_doc_id) != normalize(excluding_doc_id) &&
        exact_remote_demographics?(patient, remote) &&
        !PatientIdentifier.where(identifier_type: DDE_DOC_TYPE, identifier: remote_doc_id).exists?
    end

    return matches.first if matches.one?
    return nil if matches.empty?

    raise "Patient #{patient.id} has multiple unlinked exact DDE matches: #{matches.map { |match| match['doc_id'] }.join(', ')}"
  end

  def exact_remote_demographics?(patient, remote)
    person = patient.person
    name = person&.names&.first
    address = person&.addresses&.first
    attributes = remote['attributes'] || {}
    return false unless person && name

    local_values = [
      name.given_name,
      name.family_name,
      person.gender&.first,
      person.birthdate,
      address&.state_province,
      address&.township_division,
      address&.city_village
    ]
    remote_values = [
      remote['given_name'],
      remote['family_name'],
      remote['gender']&.first,
      remote['birthdate'],
      attributes['current_district'],
      attributes['current_traditional_authority'],
      attributes['current_village']
    ]

    local_values.zip(remote_values).all? { |local, remote_value| normalize_demographic(local) == normalize_demographic(remote_value) }
  end

  def normalize_demographic(value)
    value.to_s.strip.downcase.gsub(/[^a-z0-9]/, '')
  end

  # DDE's linking service voids the patient's old type-2 and type-3 rows before
  # saving the newly allocated NPID. Snapshot them first so every historical
  # NPID remains an active "Old identification number" alias after cleanup.
  def active_dde_identifier_snapshots(patient_id)
    PatientIdentifier.unscoped
                     .where(patient_id:, identifier_type: [DDE_NPID_TYPE, OLD_NPID_TYPE], voided: 0)
                     .order(:date_created, :patient_identifier_id)
                     .map do |identifier|
      {
        identifier: identifier.identifier.to_s.strip,
        identifier_type: identifier.identifier_type.to_i,
        location_id: identifier.location_id
      }
    end
                     .reject { |identifier| identifier[:identifier].blank? }
  end

  def consolidate_dde_identifiers!(patient_id, current_npid, previous_identifiers)
    current_doc = PatientIdentifier.where(patient_id:, identifier_type: DDE_DOC_TYPE)
                                   .order(date_created: :desc, patient_identifier_id: :desc).first
    legacy_identifiers = previous_identifiers
                         .reject { |identifier| normalize(identifier[:identifier]) == normalize(current_npid.identifier) }
                         .uniq { |identifier| normalize(identifier[:identifier]) }

    PatientIdentifier.transaction do
      PatientIdentifier.unscoped.where(patient_id:, identifier_type: DDE_NPID_TYPE)
                       .where.not(patient_identifier_id: current_npid.id).delete_all
      doc_rows = PatientIdentifier.unscoped.where(patient_id:, identifier_type: DDE_DOC_TYPE)
      current_doc ? doc_rows.where.not(patient_identifier_id: current_doc.id).delete_all : doc_rows.delete_all

      # Replace any active/voided legacy rows with one compact active row per
      # historical NPID. This retains search aliases without retaining duplicate
      # or voided identifier rows.
      PatientIdentifier.unscoped.where(patient_id:, identifier_type: OLD_NPID_TYPE).delete_all
      legacy_identifiers.each do |legacy|
        PatientIdentifier.create!(
          patient_id:,
          identifier_type: OLD_NPID_TYPE,
          identifier: legacy[:identifier],
          location_id: legacy[:location_id].presence || current_npid.location_id,
          preferred: 0
        )
      end
    end
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
          AND pi.identifier_type NOT IN (#{MULTIPLE_VALUE_EXCLUDED_IDENTIFIER_TYPES.join(', ')})
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
