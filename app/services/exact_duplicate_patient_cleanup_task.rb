# frozen_string_literal: true

require 'csv'
require 'digest'
require 'fileutils'
require 'set'

# Builds a review file for active patients whose current name, gender,
# birthdate, and current address are identical. Approved rows can then be
# merged through the existing local-patient merge service.
class ExactDuplicatePatientCleanupTask
  CONFIRMATION = 'MERGE_REVIEWED_EXACT_DUPLICATE_PATIENTS'
  UNATTENDED_CONFIRMATION = 'MERGE_ALL_EXACT_DUPLICATES_WITHOUT_REVIEW'
  DEFAULT_DATABASE = 'NDC_mahis'
  DEFAULT_APPLY_LIMIT = 25
  MAX_APPLY_LIMIT = 2_000
  MERGE_TYPE = 'Reviewed exact demographic duplicate cleanup'
  TRUTHY = %w[1 true yes y].freeze

  REVIEW_HEADERS = %w[
    approved allow_identifier_conflict identity_hash group_size
    primary_patient_id secondary_patient_id primary_created_at secondary_created_at
    given_name family_name gender birthdate village traditional_authority district
    primary_identifiers secondary_identifiers identifier_conflict
    primary_encounters secondary_encounters primary_observations secondary_observations
    primary_orders secondary_orders primary_programs secondary_programs review_note
  ].freeze
  FAILURE_HEADERS = %w[primary_patient_id secondary_patient_id error_class error_message].freeze

  def initialize(env = ENV, merger: nil)
    @apply = truthy?(env['APPLY'])
    @unattended = truthy?(env['UNATTENDED'])
    @quiet_logs = @unattended && !env['QUIET_LOGS'].to_s.match?(/\A(?:0|false|no|n)\z/i)
    @unattended_confirmation = env['UNATTENDED_CONFIRM'].to_s
    @confirmation = env['CONFIRM'].to_s
    @database_name = env.fetch('DB_NAME', DEFAULT_DATABASE).to_s
    @output_path = expanded_path(env['OUTPUT'].presence || Rails.root.join('tmp', 'exact_duplicate_patient_review.csv'))
    @failure_output_path = expanded_path(
      env['FAILURE_OUTPUT'].presence || Rails.root.join('tmp', 'exact_duplicate_patient_failures.csv')
    )
    @approval_path = expanded_path(env['APPROVAL_FILE']) if env['APPROVAL_FILE'].present?
    @operator_user_id = env['USER_ID'].to_i
    requested_limit = positive_integer(env['LIMIT'], DEFAULT_APPLY_LIMIT)
    @apply_limit = [requested_limit, MAX_APPLY_LIMIT].min
    @progress_every = positive_integer(env['PROGRESS_EVERY'], 100)
    @sync_couchdb = truthy?(env['SYNC_COUCHDB'])
    @permanent_delete = truthy?(env['PERMANENT_DELETE'])
    @delete_confirmation = env['DELETE_CONFIRM'].to_s
    @merger = merger

    validate_options!
  end

  def run
    validate_target_database!
    return export_review unless @apply
    return with_quiet_framework_logging { apply_approved_merges } if @quiet_logs

    apply_approved_merges
  end

  private

  def validate_options!
    unless @database_name.match?(/\A[A-Za-z0-9_]+\z/)
      raise ArgumentError, 'DB_NAME must contain only letters, numbers, and underscores'
    end
    return unless @apply

    unless @confirmation == CONFIRMATION
      raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required"
    end
    if @unattended
      unless @unattended_confirmation == UNATTENDED_CONFIRMATION
        raise ArgumentError, "UNATTENDED_CONFIRM=#{UNATTENDED_CONFIRMATION} is required"
      end
    else
      raise ArgumentError, 'APPROVAL_FILE is required in apply mode' if @approval_path.blank?
      raise ArgumentError, "Approval file not found: #{@approval_path}" unless File.file?(@approval_path)
    end
    raise ArgumentError, 'USER_ID must identify the operator performing the merges' unless @operator_user_id.positive?
    raise ArgumentError, 'PERMANENT_DELETE=1 is required because reviewed secondary patients must be physically removed' unless @permanent_delete
    unless @delete_confirmation == HardDeleteUnsyncablePatientsTask::CONFIRMATION
      raise ArgumentError, "DELETE_CONFIRM=#{HardDeleteUnsyncablePatientsTask::CONFIRMATION} is required"
    end
  end

  def validate_target_database!
    actual_database = connection.select_value('SELECT DATABASE()').to_s
    return if actual_database.casecmp?(@database_name)

    raise "Connected database is #{actual_database.inspect}; expected #{@database_name.inspect}"
  end

  def export_review
    rows = candidate_rows
    patient_ids = rows.flat_map { |row| [row['primary_patient_id'], row['secondary_patient_id']] }.map(&:to_i).uniq
    stats = patient_stats(patient_ids)

    FileUtils.mkdir_p(File.dirname(@output_path))
    CSV.open(@output_path, 'w', write_headers: true, headers: REVIEW_HEADERS) do |csv|
      rows.each { |row| csv << review_values(row, stats) }
    end
    File.chmod(0o600, @output_path)

    group_count = rows.map { |row| identity_hash(identity_values_from_row(row)) }.uniq.length
    conflict_count = rows.count do |row|
      identifier_conflict_from_stats?(stats[row['primary_patient_id'].to_i], stats[row['secondary_patient_id'].to_i])
    end

    puts "\n===== Exact Duplicate Patient Review ====="
    puts "Database: #{@database_name}"
    puts "Duplicate groups: #{group_count}"
    puts "Proposed secondary records: #{rows.length}"
    puts "Rows with identifier conflicts: #{conflict_count}"
    puts "Review CSV: #{@output_path}"
    puts 'No records changed.'
    puts 'Set approved=yes only after reviewing each pair.'
    puts 'Identifier conflicts require allow_identifier_conflict=yes on the same row.'
    puts 'Take and verify a database backup before applying.'
    puts "Apply a small batch with: APPLY=1 CONFIRM=#{CONFIRMATION} PERMANENT_DELETE=1 " \
         "DELETE_CONFIRM=#{HardDeleteUnsyncablePatientsTask::CONFIRMATION} USER_ID=<id> " \
         "APPROVAL_FILE=#{@output_path} LIMIT=#{DEFAULT_APPLY_LIMIT} bin/rails patients:cleanup_exact_duplicates"
  end

  def apply_approved_merges
    return apply_all_candidates if @unattended

    approved_rows = CSV.read(@approval_path, headers: true).select { |row| truthy?(row['approved']) }
    raise 'The approval file has no rows marked approved=yes' if approved_rows.empty?

    selected_rows = approved_rows.first(@apply_limit)
    with_operator_context do
      merged, = merge_rows!(selected_rows)
      finish_merged_batch!(merged)
    end

    puts "\nCompleted #{selected_rows.length} reviewed merge(s)."
    puts "#{approved_rows.length - selected_rows.length} additional approved row(s) remain beyond LIMIT=#{@apply_limit}." if approved_rows.length > selected_rows.length
  end

  def apply_all_candidates
    pending_pairs = pending_merged_secondary_pairs
    if pending_pairs.any?
      puts "\nRecovering #{pending_pairs.length} previously merged secondary patient record(s) pending permanent deletion."
      with_operator_context { permanently_delete_secondaries!(pending_pairs) }
      puts "Completed permanent deletion recovery for #{pending_pairs.length} patient record(s)."
    end

    raw_rows = candidate_rows
    if raw_rows.empty?
      puts "\nNo exact duplicate patient records remain."
      return
    end

    rows = raw_rows.map { |row| unattended_review_row(row) }
    total = 0
    failures = []

    puts "\nUnattended mode selected #{rows.length} exact duplicate patient record(s)."
    puts "Processing in batches of #{@apply_limit}; identifier conflicts will keep the primary patient's identifiers."
    with_operator_context do
      rows.each_slice(@apply_limit) do |batch|
        merged, batch_failures = merge_rows!(batch, continue_on_error: true)
        finish_merged_batch!(merged)
        total += merged.length
        failures.concat(batch_failures)
        write_failure_report(failures) if failures.any?
        puts "Completed unattended batch: #{total}/#{rows.length} patient record(s) merged and permanently deleted"
        puts "Skipped failures so far: #{failures.length}; report: #{@failure_output_path}" if failures.any?
      end
    end

    puts "\nCompleted all #{total} unattended exact-duplicate merge(s)."
    return if failures.empty?

    write_failure_report(failures)
    raise "#{failures.length} exact-duplicate merge(s) failed; details: #{@failure_output_path}"
  end

  def merge_rows!(selected_rows, continue_on_error: false)
    duplicate_secondary_ids = selected_rows.map { |row| row['secondary_patient_id'].to_i }
                                           .tally.select { |_id, count| count > 1 }.keys
    if duplicate_secondary_ids.any?
      raise "Secondary patients appear more than once in the selected batch: #{duplicate_secondary_ids.join(', ')}"
    end

    merged = []
    failures = []
    patient_cache = preload_batch_patients(selected_rows)
    selected_rows.each_with_index do |row, index|
      begin
        primary, secondary = validate_approved_pair!(row, patient_cache:)
        merge_pair!(primary, secondary)
        merged << [primary.id, secondary.id]
        completed = index + 1
        if !@unattended || (completed % @progress_every).zero? || completed == selected_rows.length
          puts "Merged #{completed}/#{selected_rows.length}: #{primary.id} <= #{secondary.id}"
        end
      rescue StandardError => e
        raise unless continue_on_error

        failure = {
          'primary_patient_id' => row['primary_patient_id'],
          'secondary_patient_id' => row['secondary_patient_id'],
          'error_class' => e.class.name,
          'error_message' => e.message
        }
        failures << failure
        warn "Skipped #{row['primary_patient_id']} <= #{row['secondary_patient_id']}: #{e.class}: #{e.message}"
      end
    end
    [merged, failures]
  end

  def write_failure_report(failures)
    FileUtils.mkdir_p(File.dirname(@failure_output_path))
    CSV.open(@failure_output_path, 'w', write_headers: true, headers: FAILURE_HEADERS) do |csv|
      failures.each { |failure| csv << FAILURE_HEADERS.map { |header| failure[header] } }
    end
    File.chmod(0o600, @failure_output_path)
  end

  def finish_merged_batch!(merged)
    permanently_delete_secondaries!(merged) if merged.any?
    enqueue_couchdb_sync(merged.map(&:first).uniq) if @sync_couchdb && merged.any?
  end

  def with_operator_context
    operator = User.unscoped.find(@operator_user_id)
    previous_user = User.current
    previous_location = Location.current
    operator_location_id = operator.location_id

    # Exact-duplicate cleanup is database-wide. Locatable's default scope uses
    # User.current.location_id, which would otherwise hide clinical records
    # created at every facility except the operator's facility. Keep the user
    # for audit columns but temporarily remove their in-memory location so the
    # merger can see and transfer records from all locations.
    operator.location_id = nil
    User.current = operator
    Location.current = nil
    yield
  ensure
    operator.location_id = operator_location_id if operator && defined?(operator_location_id)
    User.current = previous_user if defined?(previous_user)
    Location.current = previous_location if defined?(previous_location)
  end

  def with_quiet_framework_logging
    previous_active_record_logger = ActiveRecord::Base.logger
    previous_rails_log_level = Rails.logger.level
    ActiveRecord::Base.logger = nil
    Rails.logger.level = Logger::WARN
    puts 'Performance mode: SQL debug logging disabled for this unattended cleanup process.'
    yield
  ensure
    ActiveRecord::Base.logger = previous_active_record_logger if defined?(previous_active_record_logger)
    Rails.logger.level = previous_rails_log_level if defined?(previous_rails_log_level)
  end

  def unattended_review_row(row)
    row.to_h.merge(
      'approved' => 'yes',
      'allow_identifier_conflict' => 'yes',
      'identity_hash' => identity_hash(identity_values_from_row(row)),
      'review_note' => 'Automatically approved by UNATTENDED mode'
    )
  end

  def preload_batch_patients(rows)
    ids = rows.flat_map do |row|
      [row['primary_patient_id'].to_i, row['secondary_patient_id'].to_i]
    end.uniq
    Patient.includes(person: %i[names addresses]).where(patient_id: ids).index_by(&:id)
  end

  def validate_approved_pair!(row, patient_cache: nil)
    primary_id = row['primary_patient_id'].to_i
    secondary_id = row['secondary_patient_id'].to_i
    raise 'Each approved row requires different positive primary and secondary patient IDs' unless primary_id.positive? && secondary_id.positive? && primary_id != secondary_id

    primary = active_patient!(primary_id, 'primary', patient_cache:)
    secondary = active_patient!(secondary_id, 'secondary', patient_cache:)
    primary_identity = current_identity(primary)
    secondary_identity = current_identity(secondary)
    unless primary_identity == secondary_identity
      raise "Patients #{primary_id} and #{secondary_id} no longer have the same exact identity"
    end

    current_hash = identity_hash(primary_identity)
    unless secure_equal?(current_hash, row['identity_hash'].to_s)
      raise "Identity hash changed for pair #{primary_id}/#{secondary_id}; regenerate the review CSV"
    end

    if !truthy?(row['allow_identifier_conflict']) && identifier_conflict?(primary_id, secondary_id)
      raise "Identifier conflict for pair #{primary_id}/#{secondary_id}; review it and set allow_identifier_conflict=yes to override"
    end

    [primary, secondary]
  end

  def active_patient!(patient_id, role, patient_cache: nil)
    patient = patient_cache ? patient_cache[patient_id] : Patient.includes(:person).find_by(patient_id:)
    raise "The #{role} patient #{patient_id} is missing or already voided" unless patient&.person && patient.person.voided.to_i.zero?

    patient
  end

  def merge_pair!(primary, secondary)
    ActiveRecord::Base.transaction(requires_new: true) do
      merger.merge_local_patients(
        { 'patient_id' => primary.id, 'doc_id' => '' },
        { 'patient_id' => secondary.id, 'doc_id' => '' },
        MERGE_TYPE,
        identifier_strategy: :keep_primary,
        suppress_dde_footprints: true
      )
      mark_potential_duplicates_merged!(secondary.id)
    end
  end

  def permanently_delete_secondaries!(merged_pairs)
    secondary_ids = merged_pairs.map(&:last)
    secondary_states = Patient.unscoped.where(patient_id: secondary_ids)
                              .pluck(:patient_id, :voided, :void_reason)
                              .to_h { |patient_id, voided, reason| [patient_id.to_i, [voided.to_i, reason]] }
    merged_pairs.each do |primary_id, secondary_id|
      expected_reason = "Merged into patient ##{primary_id}:0"
      voided, reason = secondary_states[secondary_id]
      unless voided == 1 && reason == expected_reason
        raise "Patient #{secondary_id} was not safely merged into #{primary_id}; permanent deletion stopped"
      end
    end

    scope = lambda do
      Patient.unscoped.where(patient_id: secondary_ids, voided: 1)
    end
    deletion = HardDeleteUnsyncablePatientsTask.new(
      {
        'APPLY' => '1',
        'CONFIRM' => HardDeleteUnsyncablePatientsTask::CONFIRMATION,
        'BATCH_SIZE' => [secondary_ids.length, HardDeleteUnsyncablePatientsTask::MAX_BATCH_SIZE].min.to_s
      },
      candidate_scope: scope,
      criteria_label: 'reviewed secondary patients successfully merged by exact-duplicate cleanup'
    )
    deletion.run
  end

  def pending_merged_secondary_pairs
    MergeAudit.unscoped
              .where(merge_type: MERGE_TYPE, voided: 0)
              .joins('INNER JOIN patient pending_secondary ON pending_secondary.patient_id = merge_audits.secondary_id')
              .where('pending_secondary.voided = 1')
              .order(:id)
              .pluck(:primary_id, :secondary_id)
              .map { |primary_id, secondary_id| [primary_id.to_i, secondary_id.to_i] }
              .uniq
  end

  def mark_potential_duplicates_merged!(secondary_patient_id)
    scope = PotentialDuplicate.where(patient_id_a: secondary_patient_id)
                              .or(PotentialDuplicate.where(patient_id_b: secondary_patient_id))
    scope.update_all(
      merge_status: true,
      changed_by: User.current&.person_id,
      updated_at: Time.current
    )
  end

  def enqueue_couchdb_sync(patient_ids)
    patient_ids.each_slice(100) do |batch|
      jid = Sync::BulkPatientRecordSyncJob.perform_async(batch, { 'location_id' => nil })
      puts "Queued CouchDB rebuild #{jid} for #{batch.length} primary patient(s)"
    end
  end

  def candidate_rows
    connection.select_all(<<~SQL).to_a
      WITH ranked_names AS (
        SELECT pn.person_id, pn.given_name, pn.family_name,
               ROW_NUMBER() OVER (
                 PARTITION BY pn.person_id
                 ORDER BY pn.preferred DESC, pn.date_created DESC, pn.person_name_id DESC
               ) AS rn
        FROM person_name pn
        WHERE pn.voided = 0
      ), ranked_addresses AS (
        SELECT pa.person_id, pa.neighborhood_cell, pa.county_district, pa.address2,
               ROW_NUMBER() OVER (
                 PARTITION BY pa.person_id
                 ORDER BY pa.preferred DESC, pa.date_created DESC, pa.person_address_id DESC
               ) AS rn
        FROM person_address pa
        WHERE pa.voided = 0
      ), identities AS (
        SELECT p.patient_id, p.date_created,
               LOWER(TRIM(n.given_name)) AS given_name,
               LOWER(TRIM(n.family_name)) AS family_name,
               UPPER(TRIM(pe.gender)) AS gender,
               pe.birthdate,
               LOWER(TRIM(COALESCE(a.neighborhood_cell, ''))) AS village,
               LOWER(TRIM(COALESCE(a.county_district, ''))) AS traditional_authority,
               LOWER(TRIM(COALESCE(a.address2, ''))) AS district
        FROM patient p
        INNER JOIN person pe ON pe.person_id = p.patient_id AND pe.voided = 0
        INNER JOIN ranked_names n ON n.person_id = p.patient_id AND n.rn = 1
        INNER JOIN ranked_addresses a ON a.person_id = p.patient_id AND a.rn = 1
        WHERE p.voided = 0
          AND NULLIF(TRIM(n.given_name), '') IS NOT NULL
          AND NULLIF(TRIM(n.family_name), '') IS NOT NULL
          AND NULLIF(TRIM(pe.gender), '') IS NOT NULL
          AND pe.birthdate IS NOT NULL
          AND (
                NULLIF(TRIM(a.neighborhood_cell), '') IS NOT NULL
             OR NULLIF(TRIM(a.county_district), '') IS NOT NULL
             OR NULLIF(TRIM(a.address2), '') IS NOT NULL
          )
      ), ranked_identities AS (
        SELECT identities.*,
               FIRST_VALUE(patient_id) OVER identity_window AS primary_patient_id,
               FIRST_VALUE(date_created) OVER identity_window AS primary_created_at,
               ROW_NUMBER() OVER identity_window AS identity_rank,
               COUNT(*) OVER identity_partition AS group_size
        FROM identities
        WINDOW
          identity_partition AS (
            PARTITION BY given_name, family_name, gender, birthdate,
                         village, traditional_authority, district
          ),
          identity_window AS (
            PARTITION BY given_name, family_name, gender, birthdate,
                         village, traditional_authority, district
            ORDER BY date_created, patient_id
          )
      )
      SELECT primary_patient_id,
             patient_id AS secondary_patient_id,
             primary_created_at,
             date_created AS secondary_created_at,
             group_size,
             given_name, family_name, gender, birthdate,
             village, traditional_authority, district
      FROM ranked_identities
      WHERE group_size > 1 AND identity_rank > 1
      ORDER BY primary_patient_id, secondary_created_at, secondary_patient_id
    SQL
  end

  def patient_stats(patient_ids)
    stats = Hash.new do |hash, patient_id|
      hash[patient_id] = {
        identifiers: Hash.new { |identifier_hash, type| identifier_hash[type] = Set.new },
        encounters: 0,
        observations: 0,
        orders: 0,
        programs: 0
      }
    end

    patient_ids.each_slice(1_000) do |ids|
      PatientIdentifier.unscoped.where(patient_id: ids, voided: 0)
                       .pluck(:patient_id, :identifier_type, :identifier).each do |patient_id, type, value|
        next if value.to_s.strip.empty?

        stats[patient_id][:identifiers][type.to_i] << value.to_s.strip.upcase
      end
      assign_group_counts(stats, Encounter.where(patient_id: ids).group(:patient_id).count, :encounters)
      assign_group_counts(stats, Observation.where(person_id: ids).group(:person_id).count, :observations)
      assign_group_counts(stats, Order.where(patient_id: ids).group(:patient_id).count, :orders)
      assign_group_counts(stats, PatientProgram.where(patient_id: ids).group(:patient_id).count, :programs)
    end
    stats
  end

  def assign_group_counts(stats, counts, key)
    counts.each { |patient_id, count| stats[patient_id.to_i][key] = count.to_i }
  end

  def review_values(row, stats)
    primary_stats = stats[row['primary_patient_id'].to_i]
    secondary_stats = stats[row['secondary_patient_id'].to_i]
    values = identity_values_from_row(row)

    [
      '', '', identity_hash(values), row['group_size'],
      row['primary_patient_id'], row['secondary_patient_id'], row['primary_created_at'], row['secondary_created_at'],
      *values,
      identifier_summary(primary_stats), identifier_summary(secondary_stats),
      identifier_conflict_from_stats?(primary_stats, secondary_stats) ? 'yes' : 'no',
      primary_stats[:encounters], secondary_stats[:encounters],
      primary_stats[:observations], secondary_stats[:observations],
      primary_stats[:orders], secondary_stats[:orders],
      primary_stats[:programs], secondary_stats[:programs], ''
    ]
  end

  def identifier_summary(stats)
    stats[:identifiers].sort_by { |type, _values| type }.flat_map do |type, values|
      values.sort.map { |value| "#{type}=#{value}" }
    end.join(' | ')
  end

  def identifier_conflict?(primary_id, secondary_id)
    stats = patient_stats([primary_id, secondary_id])
    identifier_conflict_from_stats?(stats[primary_id], stats[secondary_id])
  end

  def identifier_conflict_from_stats?(primary_stats, secondary_stats)
    shared_types = primary_stats[:identifiers].keys & secondary_stats[:identifiers].keys
    shared_types.any? do |type|
      (primary_stats[:identifiers][type] | secondary_stats[:identifiers][type]).length > 1
    end
  end

  def current_identity(patient)
    name = current_person_record(
      patient.person,
      :names,
      PersonName,
      :person_name_id
    )
    address = current_person_record(
      patient.person,
      :addresses,
      PersonAddress,
      :person_address_id
    )
    raise "Patient #{patient.id} no longer has an active name and address" unless name && address

    values = [
      normalize(name.given_name),
      normalize(name.family_name),
      normalize(patient.person.gender).upcase,
      patient.person.birthdate&.to_date&.iso8601,
      normalize(address.neighborhood_cell),
      normalize(address.county_district),
      normalize(address.address2)
    ]
    if values[0..3].any?(&:blank?) || values[4..6].all?(&:blank?)
      raise "Patient #{patient.id} no longer satisfies the exact-duplicate criteria"
    end

    values
  end

  def current_person_record(person, association_name, model, primary_key)
    association = person.association(association_name)
    records = if association.loaded?
                association.target.select { |record| record.voided.to_i.zero? }
              else
                model.unscoped.where(person_id: person.id, voided: 0).to_a
              end
    records.max_by do |record|
      [record.preferred.to_i, record.date_created || Time.at(0), record.public_send(primary_key).to_i]
    end
  end

  def identity_values_from_row(row)
    %w[given_name family_name gender birthdate village traditional_authority district].map { |field| row[field].to_s }
  end

  def identity_hash(values)
    Digest::SHA256.hexdigest(values.join("\u001F"))
  end

  def normalize(value)
    value.to_s.strip.downcase
  end

  def secure_equal?(expected, actual)
    actual.length == expected.length && ActiveSupport::SecurityUtils.secure_compare(expected, actual)
  end

  def positive_integer(value, fallback)
    parsed = value.to_i
    parsed.positive? ? parsed : fallback
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

  def merger
    @merger ||= DdeMergingService.new(nil, nil)
  end
end
