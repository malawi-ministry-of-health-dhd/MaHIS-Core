# frozen_string_literal: true

require 'csv'
require 'digest'
require 'fileutils'
require 'set'

# Reverses the August 2026 exact-duplicate cleanup for ART patients by using
# the untouched pre-cleanup database as the source of truth. The task never
# deletes rows. Original rows keep their source UUIDs; later clinical rows keep
# their current UUIDs while their patient foreign keys are reassigned.
class ArtDuplicateMergeRollbackTask
  CONFIRMATION = 'RESTORE_REVIEWED_ART_DUPLICATE_MERGES_WITHOUT_DELETING'
  DEFAULT_SOURCE_DATABASE = 'mahis_dup'
  DEFAULT_TARGET_DATABASE = 'mahis_prod'
  DEFAULT_OUTPUT = 'art_duplicate_merge_rollback_review.csv'
  DEFAULT_RESULT = 'art_duplicate_merge_rollback_results.csv'
  PROGRAM_ID = 1
  ARV_IDENTIFIER_TYPE = 4
  CLEANUP_USER_ID = 1
  CLEANUP_FROM = Time.zone.parse('2026-08-05 00:00:00')
  CLEANUP_TO = Time.zone.parse('2026-08-11 00:00:00')
  VOID_REASON = 'Voided while reversing August 2026 exact-duplicate ART merge'
  TRUTHY = %w[1 true yes y].freeze

  REVIEW_HEADERS = %w[
    approved primary_source_id primary_uuid secondary_source_id secondary_uuid
    primary_arv_numbers secondary_arv_numbers cleanup_at new_encounter_count
    new_encounter_uuids recommended_new_encounter_owner_uuid
    new_encounter_owner_uuid recommendation_reason identity_hash review_note
  ].freeze
  RESULT_HEADERS = %w[primary_uuid secondary_uuid status details].freeze

  RESTORE_TABLES = {
    'person_name' => %w[person_name_id person_id],
    'person_address' => %w[person_address_id person_id],
    'person_attribute' => %w[person_attribute_id person_id],
    'patient_identifier' => %w[patient_identifier_id patient_id]
  }.freeze
  VOIDABLE_COPY_TABLES = {
    'person_attribute' => {
      owner: 'person_id', signature: %w[person_attribute_type_id value]
    },
    'patient_identifier' => {
      owner: 'patient_id', signature: %w[identifier_type identifier location_id]
    },
    'patient_program' => {
      owner: 'patient_id', signature: %w[program_id date_enrolled date_completed location_id],
      require_cleanup_creator: false
    },
    'encounter' => {
      owner: 'patient_id', signature: %w[encounter_type encounter_datetime program_id location_id]
    },
    'orders' => {
      owner: 'patient_id', signature: %w[order_type_id concept_id start_date]
    },
    'obs' => {
      owner: 'person_id',
      signature: %w[concept_id obs_datetime value_boolean value_coded value_datetime value_drug value_numeric value_text]
    }
  }.freeze

  def initialize(env = ENV, connection: ActiveRecord::Base.connection)
    @connection = connection
    @apply = truthy?(env['APPLY'])
    @approve_all = truthy?(env['APPROVE_ALL'])
    @source_database = env.fetch('SOURCE_DB', DEFAULT_SOURCE_DATABASE).to_s
    @target_database = env.fetch('TARGET_DB', DEFAULT_TARGET_DATABASE).to_s
    @output_path = expand(env['OUTPUT'].presence || Rails.root.join('tmp', DEFAULT_OUTPUT))
    @result_path = expand(env['RESULT_OUTPUT'].presence || Rails.root.join('tmp', DEFAULT_RESULT))
    @approval_path = expand(env['APPROVAL_FILE']) if env['APPROVAL_FILE'].present?
    @confirmation = env['CONFIRM'].to_s
    @operator_user_id = env['USER_ID'].to_i
    @limit = [[env.fetch('LIMIT', 100).to_i, 1].max, 500].min
    validate_options!
  end

  def run
    validate_databases!
    @apply ? apply_review : export_review
  end

  private

  def validate_options!
    [@source_database, @target_database].each do |name|
      raise ArgumentError, 'Database names may contain only letters, numbers, and underscores' unless name.match?(/\A[A-Za-z0-9_]+\z/)
    end
    raise ArgumentError, 'SOURCE_DB and TARGET_DB must differ' if @source_database.casecmp?(@target_database)
    return unless @apply

    raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required" unless @confirmation == CONFIRMATION
    raise ArgumentError, 'USER_ID must identify the operator' unless @operator_user_id.positive?
    unless @approve_all
      raise ArgumentError, 'APPROVAL_FILE is required unless APPROVE_ALL=1' if @approval_path.blank?
      raise ArgumentError, "Approval file not found: #{@approval_path}" unless File.file?(@approval_path)
    end
  end

  def validate_databases!
    databases = select_all('SELECT SCHEMA_NAME FROM information_schema.SCHEMATA').map { |row| row['SCHEMA_NAME'].downcase }
    raise "Source database #{@source_database.inspect} is not available" unless databases.include?(@source_database.downcase)
    raise "Target database #{@target_database.inspect} is not available" unless databases.include?(@target_database.downcase)

    @connection.execute("USE #{quote_table(@target_database)}")
    current = select_value('SELECT DATABASE()').to_s
    raise "Connected database is #{current.inspect}; expected #{@target_database.inspect}" unless current.casecmp?(@target_database)

    required = %w[person patient person_name person_address person_attribute patient_identifier
                  patient_program patient_state visit encounter orders drug_order obs]
    [@source_database, @target_database].each do |database|
      present = select_all(<<~SQL).map { |row| row['TABLE_NAME'] }
        SELECT TABLE_NAME FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{quote(database)}
      SQL
      missing = required - present
      raise "#{database} is missing required tables: #{missing.join(', ')}" if missing.any?
    end
    if @apply && !select_value("SELECT 1 FROM users WHERE user_id=#{@operator_user_id} LIMIT 1")
      raise "User #{@operator_user_id} does not exist in #{@target_database}"
    end
  end

  def export_review
    rows = build_review_rows
    generated = generated_copy_summary(rows)
    write_csv(@output_path, REVIEW_HEADERS, rows)
    puts "\n===== ART Duplicate Merge Rollback Review ====="
    puts "Source database: #{@source_database}"
    puts "Target database: #{@target_database}"
    puts "Affected primary patients: #{rows.map { |row| row['primary_uuid'] }.uniq.length}"
    puts "Secondary patients to restore: #{rows.length}"
    new_count = rows.group_by { |row| row['primary_uuid'] }.sum { |_uuid, group| group.first['new_encounter_count'].to_i }
    puts "New encounters requiring an owner decision: #{new_count}"
    puts "Generated merge copies to void: #{generated.values.sum} (#{generated.sort.to_h.map { |table, count| "#{table}=#{count}" }.join(', ')})"
    puts "Review CSV: #{@output_path}"
    puts 'No records changed. Set approved=yes for every row in a duplicate group.'
    puts 'For groups with new encounters, copy the recommended owner UUID or another reviewed ARV-owner UUID into new_encounter_owner_uuid.'
    puts "Apply with: APPLY=1 CONFIRM=#{CONFIRMATION} USER_ID=<id> APPROVAL_FILE=#{@output_path} " \
         'bin/rails patients:rollback_art_duplicate_merges'
    puts "Apply every discovered group without a CSV with: APPLY=1 APPROVE_ALL=1 CONFIRM=#{CONFIRMATION} " \
         'USER_ID=<id> bin/rails patients:rollback_art_duplicate_merges'
  end

  def build_review_rows
    pairs = candidate_pairs
    pairs.group_by { |row| row['primary_uuid'] }.flat_map do |_primary_uuid, group|
      enrich_group(group)
    end
  end

  def generated_copy_summary(rows)
    ids = Hash.new { |hash, table| hash[table] = Set.new }
    rows.each do |row|
      primary_id = target_person_id(row['primary_uuid'])
      source_id = row['secondary_source_id'].to_i
      VOIDABLE_COPY_TABLES.each do |table, config|
        ids[table].merge(generated_copy_ids(table, config, primary_id, source_id))
      end
      ids['patient_state'].merge(generated_state_ids(source_id, primary_id))
    end
    ids.transform_values(&:length)
  end

  def candidate_pairs
    select_all(<<~SQL)
      WITH affected AS (
        SELECT pn.person_id AS primary_source_id,
               MAX(CASE
                 WHEN pn.changed_by=#{CLEANUP_USER_ID} THEN pn.date_changed
                 ELSE pn.date_created
               END) AS cleanup_at
        FROM person_name pn
        INNER JOIN patient_program pp ON pp.patient_id=pn.person_id
        WHERE pp.program_id=#{PROGRAM_ID} AND pp.voided=0 AND pn.voided=0
          AND ((pn.creator=#{CLEANUP_USER_ID} AND pn.date_created >= #{quote(CLEANUP_FROM)} AND pn.date_created < #{quote(CLEANUP_TO)})
            OR (pn.changed_by=#{CLEANUP_USER_ID} AND pn.date_changed >= #{quote(CLEANUP_FROM)} AND pn.date_changed < #{quote(CLEANUP_TO)}))
        GROUP BY pn.person_id
      ), source_names AS (
        SELECT pn.*, ROW_NUMBER() OVER (
          PARTITION BY pn.person_id ORDER BY pn.preferred DESC, pn.date_created DESC, pn.person_name_id DESC
        ) AS row_num
        FROM #{source_table('person_name')} pn WHERE pn.voided=0
      ), source_addresses AS (
        SELECT pa.*, ROW_NUMBER() OVER (
          PARTITION BY pa.person_id ORDER BY pa.preferred DESC, pa.date_created DESC, pa.person_address_id DESC
        ) AS row_num
        FROM #{source_table('person_address')} pa WHERE pa.voided=0
      ), source_identities AS (
        SELECT p.patient_id, pe.uuid,
               LOWER(TRIM(n.given_name)) AS given_name,
               LOWER(TRIM(n.family_name)) AS family_name,
               UPPER(TRIM(pe.gender)) AS gender, pe.birthdate,
               LOWER(TRIM(COALESCE(a.neighborhood_cell, ''))) AS village,
               LOWER(TRIM(COALESCE(a.county_district, ''))) AS traditional_authority,
               LOWER(TRIM(COALESCE(a.address2, ''))) AS district
        FROM #{source_table('patient')} p
        INNER JOIN #{source_table('person')} pe ON pe.person_id=p.patient_id AND pe.voided=0
        INNER JOIN source_names n ON n.person_id=p.patient_id AND n.row_num=1
        INNER JOIN source_addresses a ON a.person_id=p.patient_id AND a.row_num=1
        WHERE p.voided=0
      )
      SELECT DISTINCT affected.primary_source_id, primary_identity.uuid AS primary_uuid,
             secondary_identity.patient_id AS secondary_source_id,
             secondary_identity.uuid AS secondary_uuid, affected.cleanup_at
      FROM affected
      INNER JOIN source_identities primary_identity
        ON primary_identity.patient_id=affected.primary_source_id
      INNER JOIN source_identities secondary_identity
        ON secondary_identity.patient_id<>primary_identity.patient_id
       AND secondary_identity.given_name=primary_identity.given_name
       AND secondary_identity.family_name=primary_identity.family_name
       AND secondary_identity.gender=primary_identity.gender
       AND secondary_identity.birthdate=primary_identity.birthdate
       AND secondary_identity.village=primary_identity.village
       AND secondary_identity.traditional_authority=primary_identity.traditional_authority
       AND secondary_identity.district=primary_identity.district
      ORDER BY affected.primary_source_id, secondary_identity.patient_id
    SQL
  end

  def enrich_group(group)
    primary = group.first
    cleanup_at = Time.zone.parse(primary['cleanup_at'].to_s)
    patient_uuids = [primary['primary_uuid']] + group.map { |row| row['secondary_uuid'] }
    source_ids = [primary['primary_source_id']] + group.map { |row| row['secondary_source_id'] }
    arvs = source_arv_numbers(source_ids)
    new_encounters = new_encounters(primary['primary_uuid'], cleanup_at)
    recommendation, reason = recommend_owner(source_ids, patient_uuids, arvs, cleanup_at)
    encounter_uuids = new_encounters.map { |row| row['uuid'] }.sort

    group.map do |pair|
      values = {
        'approved' => '',
        'primary_source_id' => pair['primary_source_id'],
        'primary_uuid' => pair['primary_uuid'],
        'secondary_source_id' => pair['secondary_source_id'],
        'secondary_uuid' => pair['secondary_uuid'],
        'primary_arv_numbers' => arvs[pair['primary_source_id'].to_i].join('|'),
        'secondary_arv_numbers' => arvs[pair['secondary_source_id'].to_i].join('|'),
        'cleanup_at' => cleanup_at.iso8601,
        'new_encounter_count' => encounter_uuids.length,
        'new_encounter_uuids' => encounter_uuids.join('|'),
        'recommended_new_encounter_owner_uuid' => recommendation,
        'new_encounter_owner_uuid' => '',
        'recommendation_reason' => reason,
        'review_note' => ''
      }
      values['identity_hash'] = review_hash(values)
      values
    end
  end

  def source_arv_numbers(source_ids)
    result = Hash.new { |hash, key| hash[key] = [] }
    return result if source_ids.empty?

    select_all(<<~SQL).each do |row|
      SELECT patient_id, identifier FROM #{source_table('patient_identifier')}
      WHERE patient_id IN (#{integers(source_ids)})
        AND identifier_type=#{ARV_IDENTIFIER_TYPE} AND voided=0
      ORDER BY patient_id, preferred DESC, date_created, patient_identifier_id
    SQL
      result[row['patient_id'].to_i] << row['identifier'].to_s
    end
    result
  end

  def new_encounters(primary_uuid, cleanup_at)
    target_id = target_person_id(primary_uuid)
    raise "Primary patient UUID #{primary_uuid} is absent from #{@target_database}" unless target_id

    select_all(<<~SQL)
      SELECT e.uuid, e.encounter_datetime, e.date_created, e.creator
      FROM encounter e
      LEFT JOIN #{source_table('encounter')} source_encounter ON source_encounter.uuid=e.uuid
      WHERE e.patient_id=#{target_id} AND e.voided=0 AND e.program_id=#{PROGRAM_ID}
        AND e.date_created >= #{quote(cleanup_at)} AND e.creator<>#{CLEANUP_USER_ID}
        AND source_encounter.encounter_id IS NULL
      ORDER BY e.encounter_datetime, e.encounter_id
    SQL
  end

  def recommend_owner(source_ids, patient_uuids, arvs, cleanup_at)
    eligible = source_ids.map(&:to_i).select { |id| arvs[id].any? }
    return ['', 'No original active ARV number was found'] if eligible.empty?

    dates = select_all(<<~SQL).to_h { |row| [row['patient_id'].to_i, row['last_encounter']] }
      SELECT patient_id, MAX(encounter_datetime) AS last_encounter
      FROM #{source_table('encounter')}
      WHERE patient_id IN (#{integers(eligible)}) AND program_id=#{PROGRAM_ID} AND voided=0
        AND encounter_datetime < #{quote(cleanup_at)}
      GROUP BY patient_id
    SQL
    winner = eligible.max_by { |id| [dates[id].to_s, -source_ids.map(&:to_i).index(id)] }
    index = source_ids.map(&:to_i).index(winner)
    [patient_uuids[index], "Original ARV owner with latest pre-cleanup ART encounter (#{dates[winner] || 'none'})"]
  end

  def apply_review
    all_rows = @approve_all ? automatically_approved_rows : CSV.read(@approval_path, headers: true)
    approved = all_rows.select { |row| truthy?(row['approved']) }
    raise 'The approval file has no rows marked approved=yes' if approved.empty?

    selected_groups = approved.group_by { |row| row['primary_uuid'].to_s }.first(@limit)
    results = []
    successful_groups = 0
    selected_groups.each do |primary_uuid, rows|
      validate_complete_group!(primary_uuid, rows, all_rows)
      @connection.transaction(requires_new: true) do
        apply_group!(rows)
      end
      rows.each do |row|
        results << result_row(row, 'restored', 'Original UUID graph restored; generated copies voided')
      end
      successful_groups += 1
      puts "Restored #{primary_uuid}: #{rows.length} secondary patient(s)"
    rescue StandardError => e
      rows.each { |row| results << result_row(row, 'failed', "#{e.class}: #{e.message}") }
      warn "Skipped #{primary_uuid}: #{e.class}: #{e.message}"
    ensure
      write_csv(@result_path, RESULT_HEADERS, results)
    end

    failures = results.count { |row| row['status'] == 'failed' }
    puts "\nCompleted #{successful_groups} group(s); result report: #{@result_path}"
    raise "#{failures} reviewed row(s) failed; successful groups remain committed" if failures.positive?
  end

  def automatically_approved_rows
    build_review_rows.map do |row|
      row['approved'] = 'yes'
      if row['new_encounter_count'].to_i.positive?
        owner = row['recommended_new_encounter_owner_uuid'].to_s
        raise "No automatic ARV owner recommendation for primary UUID #{row['primary_uuid']}" if owner.blank?

        row['new_encounter_owner_uuid'] = owner
      end
      row
    end
  end

  def validate_complete_group!(primary_uuid, rows, all_rows)
    group_rows = all_rows.select { |row| row['primary_uuid'].to_s == primary_uuid }
    unless group_rows.length == rows.length
      raise "Every row for primary UUID #{primary_uuid} must be approved together"
    end
    raise "Primary UUID #{primary_uuid} is blank" if primary_uuid.blank?
    secondary_uuids = rows.map { |row| row['secondary_uuid'].to_s }
    raise "Secondary UUIDs must be unique within #{primary_uuid}" unless secondary_uuids.uniq.length == rows.length

    rows.each do |row|
      raise "Review row hash changed for #{row['secondary_uuid']}" unless secure_equal?(review_hash(row), row['identity_hash'])
      raise 'Primary and secondary UUID must differ' if row['secondary_uuid'].blank? || row['secondary_uuid'] == primary_uuid
    end
    encounter_lists = rows.map { |row| split_values(row['new_encounter_uuids']).sort }.uniq
    owners = rows.map { |row| row['new_encounter_owner_uuid'].to_s.strip }.uniq
    raise "New encounter list differs inside group #{primary_uuid}" unless encounter_lists.one?
    raise "Encounter owner differs inside group #{primary_uuid}" unless owners.one?
    raise "A reviewed new_encounter_owner_uuid is required for #{primary_uuid}" if encounter_lists.first.any? && owners.first.blank?

    cleanup_at = Time.zone.parse(rows.first['cleanup_at'].to_s)
    current_encounters = new_encounters(primary_uuid, cleanup_at).map { |encounter| encounter['uuid'] }.sort
    reviewed_encounters = encounter_lists.first
    unexpected = current_encounters - reviewed_encounters
    unless unexpected.empty?
      raise "New encounters changed for #{primary_uuid}; regenerate and review the CSV"
    end
    missing_from_primary = reviewed_encounters - current_encounters
    validate_previously_moved_encounters!(missing_from_primary, owners.first) if missing_from_primary.any?
  end

  def validate_previously_moved_encounters!(encounter_uuids, owner_uuid)
    owner_id = target_person_id(owner_uuid)
    raise "Reviewed encounter owner #{owner_uuid} does not exist" unless owner_id

    count = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM encounter
      WHERE uuid IN (#{strings(encounter_uuids)}) AND patient_id=#{owner_id} AND voided=0
        AND creator<>#{CLEANUP_USER_ID}
        AND uuid NOT IN (SELECT uuid FROM #{source_table('encounter')})
    SQL
    return if count == encounter_uuids.length

    raise 'Reviewed encounters are no longer on either the primary or selected ARV owner'
  end

  def apply_group!(rows)
    primary_uuid = rows.first['primary_uuid']
    primary_source_id = rows.first['primary_source_id'].to_i
    validate_source_identity!(primary_source_id, primary_uuid, 'primary')
    rows.each do |row|
      validate_source_identity!(row['secondary_source_id'].to_i, row['secondary_uuid'], 'secondary')
    end
    primary_target_id = target_person_id(primary_uuid)
    raise "Primary UUID #{primary_uuid} no longer exists" unless primary_target_id

    restore_primary_demographics!(primary_source_id, primary_target_id)
    restore_primary_rows_voided_by_merge!(primary_source_id)
    restored = rows.to_h do |row|
      source_id = row['secondary_source_id'].to_i
      [row['secondary_uuid'], restore_patient_graph!(source_id)]
    end
    rows.each do |row|
      void_generated_copies!(row['secondary_source_id'].to_i, primary_target_id)
      reverse_cleanup_metadata!(primary_source_id, row['secondary_source_id'].to_i)
    end

    owner_uuid = rows.first['new_encounter_owner_uuid'].to_s.strip
    encounter_uuids = split_values(rows.first['new_encounter_uuids'])
    return if encounter_uuids.empty?

    allowed = [primary_uuid] + restored.keys
    raise "Encounter owner #{owner_uuid} is not in the reviewed duplicate group" unless allowed.include?(owner_uuid)
    owner_id = owner_uuid == primary_uuid ? primary_target_id : restored.fetch(owner_uuid)
    ensure_active_arv_owner!(owner_id)
    move_new_encounters!(encounter_uuids, primary_target_id, owner_id, Time.zone.parse(rows.first['cleanup_at']))
  end

  def restore_primary_demographics!(source_id, target_id)
    restore_original_row!('person', 'person_id', source_row!('person', 'person_id', source_id), target_id, overwrite: true)
    %w[person_name person_address].each do |table|
      source_rows(table, owner_column(table), source_id).each do |row|
        restore_uuid_row!(table, primary_key(table), row, { owner_column(table) => target_id }, overwrite: true)
      end
    end
  end

  def restore_primary_rows_voided_by_merge!(source_patient_id)
    {
      'person_attribute' => ['person_id', source_patient_id],
      'patient_identifier' => ['patient_id', source_patient_id],
      'patient_program' => ['patient_id', source_patient_id],
      'encounter' => ['patient_id', source_patient_id],
      'orders' => ['patient_id', source_patient_id],
      'obs' => ['person_id', source_patient_id]
    }.each do |table, (owner, owner_id)|
      source_rows(table, owner, owner_id).each do |source_record|
        target = select_all(<<~SQL).first
          SELECT * FROM #{quote_table(table)}
          WHERE uuid=#{quote(source_record['uuid'])} AND voided=1 AND voided_by=#{CLEANUP_USER_ID}
            AND date_voided >= #{quote(CLEANUP_FROM)} AND date_voided < #{quote(CLEANUP_TO)}
            AND void_reason LIKE 'Merged into patient #%'
          LIMIT 1
        SQL
        next unless target

        update_columns(
          table, primary_key(table), target[primary_key(table)],
          'voided' => source_record['voided'], 'voided_by' => source_record['voided_by'],
          'date_voided' => source_record['date_voided'], 'void_reason' => source_record['void_reason']
        )
      end
    end
  end

  def restore_patient_graph!(source_patient_id)
    person = source_row!('person', 'person_id', source_patient_id)
    target_id = target_person_id(person['uuid'])
    if target_id
      restore_original_row!('person', 'person_id', person, target_id, overwrite: true)
    else
      target_id = insert_uuid_row!('person', 'person_id', person, {})
    end
    restore_patient_row!(source_patient_id, target_id)

    RESTORE_TABLES.each do |table, (_pk, owner)|
      source_rows(table, owner, source_patient_id).each do |row|
        restore_uuid_row!(table, primary_key(table), row, { owner => target_id }, overwrite: true)
      end
    end

    visit_map = restore_owned_rows!('visit', 'visit_id', 'patient_id', source_patient_id, target_id)
    program_map = restore_owned_rows!('patient_program', 'patient_program_id', 'patient_id', source_patient_id, target_id)
    source_rows('patient_state', 'patient_program_id', program_map.keys).each do |row|
      restore_uuid_row!('patient_state', 'patient_state_id', row,
                        { 'patient_program_id' => program_map.fetch(row['patient_program_id'].to_i) }, overwrite: true)
    end

    encounter_map = {}
    source_rows('encounter', 'patient_id', source_patient_id).each do |row|
      overrides = { 'patient_id' => target_id }
      overrides['visit_id'] = visit_map[row['visit_id'].to_i] if row['visit_id']
      encounter_map[row['encounter_id'].to_i] = restore_uuid_row!(
        'encounter', 'encounter_id', row, overrides, overwrite: true
      )
    end
    restore_clinical_children!(source_patient_id, target_id, encounter_map)
    target_id
  end

  def restore_patient_row!(source_id, target_id)
    row = source_row!('patient', 'patient_id', source_id).merge('patient_id' => target_id)
    if select_value("SELECT 1 FROM patient WHERE patient_id=#{target_id} LIMIT 1")
      update_columns('patient', 'patient_id', target_id, row.except('patient_id'))
    else
      insert_row!('patient', row)
    end
  end

  def restore_owned_rows!(table, pk, owner, source_id, target_id)
    source_rows(table, owner, source_id).to_h do |row|
      id = restore_uuid_row!(table, pk, row, { owner => target_id }, overwrite: true)
      [row[pk].to_i, id]
    end
  end

  def restore_clinical_children!(source_patient_id, target_id, encounter_map)
    order_map = {}
    source_rows('orders', 'patient_id', source_patient_id).each do |row|
      overrides = { 'patient_id' => target_id, 'obs_id' => nil }
      overrides['encounter_id'] = encounter_map[row['encounter_id'].to_i] if row['encounter_id']
      order_map[row['order_id'].to_i] = restore_uuid_row!('orders', 'order_id', row, overrides, overwrite: true)
    end

    obs_map = {}
    observations = source_rows('obs', 'person_id', source_patient_id)
    observations.each do |row|
      overrides = { 'person_id' => target_id, 'obs_group_id' => nil }
      overrides['encounter_id'] = encounter_map[row['encounter_id'].to_i] if row['encounter_id']
      overrides['order_id'] = order_map[row['order_id'].to_i] if row['order_id']
      obs_map[row['obs_id'].to_i] = restore_uuid_row!('obs', 'obs_id', row, overrides, overwrite: true)
    end
    observations.each do |row|
      next unless row['obs_group_id'] && obs_map[row['obs_group_id'].to_i]

      update_columns('obs', 'obs_id', obs_map.fetch(row['obs_id'].to_i),
                     'obs_group_id' => obs_map.fetch(row['obs_group_id'].to_i))
    end
    source_rows('orders', 'patient_id', source_patient_id).each do |row|
      next unless row['obs_id'] && obs_map[row['obs_id'].to_i]

      update_columns('orders', 'order_id', order_map.fetch(row['order_id'].to_i),
                     'obs_id' => obs_map.fetch(row['obs_id'].to_i))
    end
    order_map.each do |source_order_id, target_order_id|
      drug_order = source_row('drug_order', 'order_id', source_order_id)
      next unless drug_order

      values = drug_order.merge('order_id' => target_order_id)
      if select_value("SELECT 1 FROM drug_order WHERE order_id=#{target_order_id} LIMIT 1")
        update_columns('drug_order', 'order_id', target_order_id, values.except('order_id'))
      else
        insert_row!('drug_order', values)
      end
    end
  end

  def void_generated_copies!(source_patient_id, primary_target_id)
    VOIDABLE_COPY_TABLES.each do |table, config|
      void_rows!(table, primary_key(table), generated_copy_ids(table, config, primary_target_id, source_patient_id))
    end
    void_generated_states!(source_patient_id, primary_target_id)
    void_children_of_voided_encounters!(primary_target_id)
  end

  def void_generated_states!(source_patient_id, primary_target_id)
    void_rows!('patient_state', 'patient_state_id', generated_state_ids(source_patient_id, primary_target_id))
  end

  def generated_state_ids(source_patient_id, primary_target_id)
    select_all(<<~SQL).map { |row| row['patient_state_id'].to_i }
      SELECT DISTINCT target.patient_state_id
      FROM patient_state target
      INNER JOIN patient_program target_program
        ON target_program.patient_program_id=target.patient_program_id
       AND target_program.patient_id=#{primary_target_id}
      INNER JOIN #{source_table('patient_program')} source_program
        ON source_program.patient_id=#{source_patient_id}
       AND source_program.program_id=target_program.program_id
       AND source_program.voided=0
      INNER JOIN #{source_table('patient_state')} source
        ON source.patient_program_id=source_program.patient_program_id AND source.voided=0
       AND target.state <=> source.state
       AND target.start_date <=> source.start_date
       AND target.end_date <=> source.end_date
      LEFT JOIN #{source_table('patient_state')} original_uuid ON original_uuid.uuid=target.uuid
      WHERE target.voided=0 AND original_uuid.uuid IS NULL
        AND target.date_created >= #{quote(CLEANUP_FROM)} AND target.date_created < #{quote(CLEANUP_TO)}
    SQL
  end

  def reverse_cleanup_metadata!(primary_source_id, secondary_source_id)
    if target_columns('merge_audits').include?('voided')
      select_all(<<~SQL).each do |row|
        SELECT id FROM merge_audits
        WHERE primary_id=#{primary_source_id} AND secondary_id=#{secondary_source_id} AND voided=0
          AND created_at >= #{quote(CLEANUP_FROM)} AND created_at < #{quote(CLEANUP_TO)}
      SQL
        void_row!('merge_audits', 'id', row['id'])
      end
    end
    return unless target_columns('potential_duplicates').include?('merge_status')

    update_where(
      'potential_duplicates',
      { 'merge_status' => false, 'changed_by' => @operator_user_id, 'updated_at' => Time.current },
      "((patient_id_a=#{primary_source_id} AND patient_id_b=#{secondary_source_id}) OR " \
      "(patient_id_a=#{secondary_source_id} AND patient_id_b=#{primary_source_id})) AND merge_status=1"
    )
  end

  def generated_copy_ids(table, config, primary_id, source_patient_id)
    signatures = config[:signature].map do |column|
      "target.#{quote_column(column)} <=> source.#{quote_column(column)}"
    end
    creator = config[:require_cleanup_creator] == false ? nil : "target.creator=#{CLEANUP_USER_ID}"
    clauses = ["target.#{quote_column(config[:owner])}=#{primary_id}", 'target.voided=0', 'source.voided=0',
               'original_uuid.uuid IS NULL',
               "target.date_created >= #{quote(CLEANUP_FROM)}", "target.date_created < #{quote(CLEANUP_TO)}",
               creator, *signatures].compact
    select_all(<<~SQL).map { |row| row[primary_key(table)].to_i }
      SELECT DISTINCT target.#{quote_column(primary_key(table))}
      FROM #{quote_table(table)} target
      INNER JOIN #{source_table(table)} source
        ON source.#{quote_column(config[:owner])}=#{source_patient_id}
      LEFT JOIN #{source_table(table)} original_uuid ON original_uuid.uuid=target.uuid
      WHERE #{clauses.join(' AND ')}
    SQL
  end

  def void_children_of_voided_encounters!(primary_id)
    encounter_ids = select_all(<<~SQL).map { |row| row['encounter_id'].to_i }
      SELECT encounter_id FROM encounter
      WHERE patient_id=#{primary_id} AND voided=1 AND void_reason=#{quote(VOID_REASON)}
    SQL
    return if encounter_ids.empty?

    %w[obs orders].each do |table|
      primary = primary_key(table)
      ids = select_all("SELECT #{primary} FROM #{quote_table(table)} WHERE encounter_id IN (#{integers(encounter_ids)}) AND voided=0")
            .map { |row| row[primary].to_i }
      void_rows!(table, primary, ids)
    end
  end

  def move_new_encounters!(uuids, from_id, to_id, cleanup_at)
    rows = select_all("SELECT * FROM encounter WHERE uuid IN (#{strings(uuids)})")
    found = rows.map { |row| row['uuid'] }.to_set
    missing = uuids.reject { |uuid| found.include?(uuid) }
    raise "Reviewed encounter UUIDs are missing: #{missing.join(', ')}" if missing.any?

    rows.each do |row|
      unless [from_id, to_id].include?(row['patient_id'].to_i) && row['voided'].to_i.zero? && row['creator'].to_i != CLEANUP_USER_ID &&
             Time.zone.parse(row['date_created'].to_s) >= cleanup_at && !source_uuid_exists?('encounter', row['uuid'])
        raise "Encounter #{row['uuid']} changed after review"
      end
    end
    movable = rows.select { |row| row['patient_id'].to_i == from_id }
    return if movable.empty?
    if to_id != from_id && movable.length != rows.length
      raise 'Reviewed encounters are split between the primary and selected owner; no changes made'
    end

    encounter_ids = movable.map { |row| row['encounter_id'].to_i }
    visit_ids = rows.filter_map { |row| row['visit_id']&.to_i }.uniq
    ensure_visits_are_not_shared!(visit_ids, encounter_ids)

    update_where('encounter', { 'patient_id' => to_id }, "encounter_id IN (#{integers(encounter_ids)})")
    update_where('orders', { 'patient_id' => to_id }, "encounter_id IN (#{integers(encounter_ids)})")
    update_where('obs', { 'person_id' => to_id }, "encounter_id IN (#{integers(encounter_ids)})")
    update_encounter_dependents!(encounter_ids, to_id)
    update_where('visit', { 'patient_id' => to_id }, "visit_id IN (#{integers(visit_ids)})") if visit_ids.any?
  end

  def update_encounter_dependents!(encounter_ids, owner_id)
    tables = select_all(<<~SQL)
      SELECT table_info.TABLE_NAME,
             MAX(columns_info.COLUMN_NAME='patient_id') AS has_patient_id,
             MAX(columns_info.COLUMN_NAME='person_id') AS has_person_id
      FROM information_schema.TABLES table_info
      INNER JOIN information_schema.COLUMNS encounter_column
        ON encounter_column.TABLE_SCHEMA=table_info.TABLE_SCHEMA
       AND encounter_column.TABLE_NAME=table_info.TABLE_NAME
       AND encounter_column.COLUMN_NAME='encounter_id'
      INNER JOIN information_schema.COLUMNS columns_info
        ON columns_info.TABLE_SCHEMA=table_info.TABLE_SCHEMA
       AND columns_info.TABLE_NAME=table_info.TABLE_NAME
       AND columns_info.COLUMN_NAME IN ('patient_id', 'person_id')
      WHERE table_info.TABLE_SCHEMA=#{quote(@target_database)}
        AND table_info.TABLE_TYPE='BASE TABLE'
        AND table_info.TABLE_NAME NOT IN ('encounter', 'orders', 'obs')
      GROUP BY table_info.TABLE_NAME
    SQL
    tables.each do |row|
      attributes = {}
      attributes['patient_id'] = owner_id if row['has_patient_id'].to_i.positive?
      attributes['person_id'] = owner_id if row['has_person_id'].to_i.positive?
      update_where(row['TABLE_NAME'], attributes, "encounter_id IN (#{integers(encounter_ids)})")
    end
  end

  def ensure_visits_are_not_shared!(visit_ids, moved_encounter_ids)
    return if visit_ids.empty?

    shared = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM encounter
      WHERE visit_id IN (#{integers(visit_ids)})
        AND encounter_id NOT IN (#{integers(moved_encounter_ids)}) AND voided=0
    SQL
    raise 'A reviewed encounter shares its visit with an encounter that is not being moved' if shared.positive?
  end

  def ensure_active_arv_owner!(patient_id)
    exists = select_value(<<~SQL)
      SELECT 1 FROM patient_identifier
      WHERE patient_id=#{patient_id} AND identifier_type=#{ARV_IDENTIFIER_TYPE} AND voided=0
        AND NULLIF(TRIM(identifier), '') IS NOT NULL LIMIT 1
    SQL
    raise "Selected encounter owner #{patient_id} has no active ARV number" unless exists
  end

  def restore_uuid_row!(table, pk, source_record, overrides, overwrite:)
    existing = select_all("SELECT * FROM #{quote_table(table)} WHERE uuid=#{quote(source_record['uuid'])} LIMIT 1").first
    return insert_uuid_row!(table, pk, source_record, overrides) unless existing

    attributes = overwrite ? source_record.except(pk) : {}
    update_columns(table, pk, existing[pk], attributes.merge(overrides))
    existing[pk].to_i
  end

  def restore_original_row!(table, pk, source_record, target_id, overwrite:)
    attributes = overwrite ? source_record.except(pk) : {}
    update_columns(table, pk, target_id, attributes)
    target_id
  end

  def insert_uuid_row!(table, pk, source_record, overrides)
    insert_row!(table, source_record.except(pk).merge(overrides))
    select_value("SELECT #{quote_column(pk)} FROM #{quote_table(table)} WHERE uuid=#{quote(source_record['uuid'])} LIMIT 1").to_i
  end

  def insert_row!(table, attributes)
    allowed = target_columns(table)
    values = attributes.slice(*allowed)
    raise "No insertable columns for #{table}" if values.empty?

    @connection.execute(<<~SQL.squish)
      INSERT INTO #{quote_table(table)} (#{values.keys.map { |column| quote_column(column) }.join(', ')})
      VALUES (#{values.values.map { |value| quote(value) }.join(', ')})
    SQL
  end

  def update_columns(table, pk, id, attributes)
    update_where(table, attributes, "#{quote_column(pk)}=#{quote(id)}")
  end

  def update_where(table, attributes, condition)
    values = attributes.slice(*target_columns(table))
    return if values.empty?

    assignments = values.map { |column, value| "#{quote_column(column)}=#{quote(value)}" }.join(', ')
    @connection.execute("UPDATE #{quote_table(table)} SET #{assignments} WHERE #{condition}")
  end

  def void_row!(table, pk, id)
    update_columns(table, pk, id,
                   'voided' => 1, 'voided_by' => @operator_user_id, 'date_voided' => Time.current,
                   'void_reason' => VOID_REASON)
  end

  def void_rows!(table, pk, ids)
    ids.map(&:to_i).uniq.each_slice(1_000) do |batch|
      update_where(
        table,
        { 'voided' => 1, 'voided_by' => @operator_user_id, 'date_voided' => Time.current,
          'void_reason' => VOID_REASON },
        "#{quote_column(pk)} IN (#{integers(batch)}) AND voided=0"
      )
    end
  end

  def source_rows(table, owner, ids)
    values = Array(ids).map(&:to_i)
    return [] if values.empty?

    select_all("SELECT * FROM #{source_table(table)} WHERE #{quote_column(owner)} IN (#{integers(values)})")
  end

  def source_row(table, key, value)
    select_all("SELECT * FROM #{source_table(table)} WHERE #{quote_column(key)}=#{quote(value)} LIMIT 1").first
  end

  def source_row!(table, key, value)
    source_row(table, key, value) || raise("Source #{table}.#{key}=#{value} is missing")
  end

  def source_uuid_exists?(table, uuid)
    select_value("SELECT 1 FROM #{source_table(table)} WHERE uuid=#{quote(uuid)} LIMIT 1").present?
  end

  def validate_source_identity!(source_id, expected_uuid, role)
    actual = source_row!('person', 'person_id', source_id)['uuid'].to_s
    return if secure_equal?(actual, expected_uuid.to_s)

    raise "Reviewed #{role} source ID #{source_id} no longer resolves to UUID #{expected_uuid}"
  end

  def target_person_id(uuid)
    value = select_value("SELECT person_id FROM person WHERE uuid=#{quote(uuid)} LIMIT 1")
    value&.to_i
  end

  def owner_column(table)
    table == 'patient_identifier' ? 'patient_id' : 'person_id'
  end

  def primary_key(table)
    {
      'person' => 'person_id', 'person_name' => 'person_name_id', 'person_address' => 'person_address_id',
      'person_attribute' => 'person_attribute_id', 'patient_identifier' => 'patient_identifier_id',
      'patient_program' => 'patient_program_id', 'patient_state' => 'patient_state_id',
      'visit' => 'visit_id', 'encounter' => 'encounter_id', 'orders' => 'order_id', 'obs' => 'obs_id',
      'merge_audits' => 'id'
    }.fetch(table)
  end

  def target_columns(table)
    @target_columns ||= {}
    @target_columns[table] ||= @connection.columns(table).map(&:name)
  end

  def review_hash(row)
    fields = %w[primary_source_id primary_uuid secondary_source_id secondary_uuid cleanup_at
                new_encounter_count new_encounter_uuids recommended_new_encounter_owner_uuid]
    Digest::SHA256.hexdigest(fields.map { |field| row[field].to_s }.join("\0"))
  end

  def result_row(row, status, details)
    { 'primary_uuid' => row['primary_uuid'], 'secondary_uuid' => row['secondary_uuid'], 'status' => status, 'details' => details }
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(File.dirname(path))
    CSV.open(path, 'w', write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
    File.chmod(0o600, path)
  end

  def null_safe_equal(column, value)
    value.nil? ? "#{column} IS NULL" : "#{column}=#{quote(value)}"
  end

  def source_table(table)
    "#{quote_table(@source_database)}.#{quote_table(table)}"
  end

  def quote_table(value)
    @connection.quote_table_name(value)
  end

  def quote_column(value)
    @connection.quote_column_name(value)
  end

  def quote(value)
    @connection.quote(value)
  end

  def integers(values)
    values.map(&:to_i).join(',')
  end

  def strings(values)
    values.map { |value| quote(value) }.join(',')
  end

  def split_values(value)
    value.to_s.split('|').map(&:strip).reject(&:blank?).uniq
  end

  def select_all(sql)
    @connection.select_all(sql).to_a
  end

  def select_value(sql)
    @connection.select_value(sql)
  end

  def truthy?(value)
    TRUTHY.include?(value.to_s.strip.downcase)
  end

  def secure_equal?(left, right)
    left.present? && right.present? && left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
  end

  def expand(path)
    File.expand_path(path.to_s, Rails.root)
  end
end
