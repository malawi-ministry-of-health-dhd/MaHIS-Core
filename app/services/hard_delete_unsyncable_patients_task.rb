# frozen_string_literal: true

# Permanently removes complete patient records for active patients that have no
# valid type-3 identifier and no patient_program row. This is intentionally a
# separate task from the recoverable void workflow.
class HardDeleteUnsyncablePatientsTask
  CONFIRMATION = 'HARD_DELETE_COMPLETE_PATIENT_RECORDS'
  DEFAULT_BATCH_SIZE = 500
  MAX_BATCH_SIZE = 2_000

  TEMP_CANDIDATES = 'tmp_hard_delete_patient_candidates'
  TEMP_BATCH = 'tmp_hard_delete_patient_batch'
  TEMP_ENCOUNTERS = 'tmp_hard_delete_encounters'
  TEMP_OBSERVATIONS = 'tmp_hard_delete_observations'
  TEMP_ORDERS = 'tmp_hard_delete_orders'
  TEMP_VISITS = 'tmp_hard_delete_visits'
  TEMP_PERSONS = 'tmp_hard_delete_persons'
  TEMP_TABLES = [
    TEMP_CANDIDATES,
    TEMP_BATCH,
    TEMP_ENCOUNTERS,
    TEMP_OBSERVATIONS,
    TEMP_ORDERS,
    TEMP_VISITS,
    TEMP_PERSONS
  ].freeze

  MISSING_TYPE3_SQL = VoidUnsyncablePatientsTask::MISSING_TYPE3_SQL
  NO_PROGRAM_SQL = VoidUnsyncablePatientsTask::NO_PROGRAM_SQL
  TEST_NAME_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM person_name cleanup_name
      WHERE cleanup_name.person_id = patient.patient_id
        AND cleanup_name.voided = 0
        AND (
          LOWER(TRIM(cleanup_name.given_name)) = 'test'
          OR LOWER(TRIM(cleanup_name.family_name)) = 'test'
        )
    )
  SQL

  CLINICAL_DATA_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM encounter cleanup_encounter
      WHERE cleanup_encounter.patient_id = patient.patient_id
    )
    OR EXISTS (
      SELECT 1 FROM obs cleanup_observation
      WHERE cleanup_observation.person_id = patient.patient_id
    )
    OR EXISTS (
      SELECT 1 FROM orders cleanup_order
      WHERE cleanup_order.patient_id = patient.patient_id
    )
  SQL

  SHARED_PERSON_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM users cleanup_user
      WHERE cleanup_user.person_id = patient.patient_id
    )
    OR EXISTS (
      SELECT 1 FROM encounter cleanup_provider_encounter
      WHERE cleanup_provider_encounter.provider_id = patient.patient_id
    )
    OR EXISTS (
      SELECT 1 FROM logic_rule_token cleanup_token
      WHERE cleanup_token.creator = patient.patient_id
         OR cleanup_token.changed_by = patient.patient_id
    )
  SQL

  def initialize(env = ENV, candidate_scope: nil, criteria_label: nil, **legacy_env)
    env = legacy_env if legacy_env.any?
    @apply = env['APPLY'].to_s == '1'
    @confirmation = env['CONFIRM'].to_s
    requested_batch_size = positive_integer(env['BATCH_SIZE'], DEFAULT_BATCH_SIZE)
    @batch_size = [requested_batch_size, MAX_BATCH_SIZE].min
    @candidate_scope_override = candidate_scope
    @criteria_label = criteria_label

    validate_options!
  end

  def run
    candidate_count = candidate_scope.count
    clinical_count = candidate_scope.where(CLINICAL_DATA_SQL).count
    shared_person_count = candidate_scope.where(SHARED_PERSON_SQL).count
    print_report(candidate_count, clinical_count, shared_person_count)
    return print_dry_run_help unless @apply

    hard_delete(candidate_count)
  end

  private

  def positive_integer(value, fallback)
    parsed = value.to_i
    parsed.positive? ? parsed : fallback
  end

  def validate_options!
    return unless @apply

    unless @confirmation == CONFIRMATION
      raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required"
    end
  end

  def candidate_scope
    return @candidate_scope_override.call if @candidate_scope_override

    Patient.unscoped
           .where(voided: 0)
           .where(
             "(#{MISSING_TYPE3_SQL} AND #{NO_PROGRAM_SQL}) OR #{TEST_NAME_SQL}"
           )
  end

  def print_report(candidate_count, clinical_count, shared_person_count)
    puts "\n===== HARD DELETE Unsyncable Patient Records ====="
    if @criteria_label
      puts "Criteria: #{@criteria_label}"
    else
      puts 'Criteria: active patient matching either:'
      puts '  - no valid type-3 identifier and no patient_program row'
      puts '  - active given name or family name equals "test"'
    end
    puts "Complete patient records selected: #{candidate_count}"
    puts "Selected patients with clinical data: #{clinical_count}"
    puts "Shared staff/provider person identities retained: #{shared_person_count}"
    puts "Action: #{@apply ? 'PERMANENT DELETE' : 'DRY RUN'}"
    puts "Batch size: #{@batch_size}"
    sample_ids = candidate_scope.order(:patient_id).limit(20).pluck(:patient_id)
    puts "Sample IDs: #{sample_ids.join(', ')}" if sample_ids.any?
    puts
  end

  def print_dry_run_help
    puts 'No records changed.'
    puts 'This operation does not create a backup and cannot be undone.'
    puts 'Apply only after taking and verifying an external database backup:'
    puts "  APPLY=1 CONFIRM=#{CONFIRMATION} bin/rails patients:hard_delete_unsyncable"
  end

  def hard_delete(initial_count)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      create_temp_tables(connection)
      snapshot_candidates(connection)
      snapshot_count = temp_count(connection, TEMP_CANDIDATES)
      unless snapshot_count == initial_count
        raise "Candidate snapshot changed from #{initial_count} to #{snapshot_count}; nothing was deleted"
      end

      total_deleted = 0
      last_patient_id = 0

      loop do
        batch_count, last_patient_id = prepare_batch(connection, last_patient_id)
        break if batch_count.zero?

        verify_batch_still_eligible!(connection, batch_count)
        delete_batch(connection)
        total_deleted += batch_count
        puts "Deleted #{total_deleted}/#{snapshot_count} complete patient record(s)"
      end

      deleted_persons = delete_candidate_persons(connection, snapshot_count)
      retained_persons = snapshot_count - deleted_persons
      puts "\nCompleted. Permanently deleted #{total_deleted} patient record(s)."
      puts "Retained #{retained_persons} shared staff/provider person identity record(s)."
    ensure
      drop_temp_tables(connection)
    end
  end

  def create_temp_tables(connection)
    TEMP_TABLES.each do |table_name|
      quoted_table = connection.quote_table_name(table_name)
      connection.execute("DROP TEMPORARY TABLE IF EXISTS #{quoted_table}")
      connection.execute(<<~SQL.squish)
        CREATE TEMPORARY TABLE #{quoted_table} (
          id BIGINT NOT NULL PRIMARY KEY
        ) ENGINE=InnoDB
      SQL
    end
  end

  def snapshot_candidates(connection)
    table = connection.quote_table_name(TEMP_CANDIDATES)
    sql = candidate_scope.select(:patient_id).to_sql
    connection.execute("INSERT INTO #{table} (id) #{sql}")
  end

  def prepare_batch(connection, last_patient_id)
    truncate_temp_table(connection, TEMP_BATCH)
    batch = connection.quote_table_name(TEMP_BATCH)
    candidates = connection.quote_table_name(TEMP_CANDIDATES)
    connection.execute(<<~SQL.squish)
      INSERT INTO #{batch} (id)
      SELECT id
      FROM #{candidates}
      WHERE id > #{last_patient_id.to_i}
      ORDER BY id
      LIMIT #{@batch_size}
    SQL

    row = connection.select_rows("SELECT COUNT(*), MAX(id) FROM #{batch}").first
    [row[0].to_i, row[1].to_i]
  end

  def delete_batch(connection)
    prepare_related_ids(connection)
    # MySQL GTID consistency does not allow a transaction that writes both
    # InnoDB and non-transactional (for example MyISAM) tables. These legacy
    # references are safe to delete first: the patient remains a candidate
    # until the transactional deletion below succeeds, so a retry is
    # idempotent if a later statement fails.
    delete_nontransactional_patient_references(connection)

    ActiveRecord::Base.transaction(requires_new: true) do
      break_circular_clinical_references(connection)
      delete_nested_clinical_children(connection)
      delete_nonstandard_foreign_keys(connection)

      delete_tables_with_column(
        connection,
        'obs_id',
        TEMP_OBSERVATIONS,
        except: %w[obs orders]
      )
      delete_tables_with_column(
        connection,
        'order_id',
        TEMP_ORDERS,
        except: %w[obs orders]
      )
      delete_tables_with_column(
        connection,
        'encounter_id',
        TEMP_ENCOUNTERS,
        except: %w[encounter obs orders]
      )

      delete_join(connection, 'obs', 'obs_id', TEMP_OBSERVATIONS)
      delete_join(connection, 'orders', 'order_id', TEMP_ORDERS)

      rehome_visits_with_surviving_encounters(connection)
      delete_tables_with_column(
        connection,
        'visit_id',
        TEMP_VISITS,
        except: %w[encounter visit]
      )
      delete_join(connection, 'encounter', 'encounter_id', TEMP_ENCOUNTERS)
      delete_join(connection, 'visit', 'visit_id', TEMP_VISITS)

      delete_merge_audits(connection)
      delete_nonstandard_patient_references(connection)
      delete_patient_program_children(connection)
      delete_tables_with_column(
        connection,
        'patient_id',
        TEMP_BATCH,
        except: %w[patient encounter obs orders visit]
      )
      delete_join(connection, 'patient', 'patient_id', TEMP_BATCH)
    end
  end

  def delete_candidate_persons(connection, candidate_count)
    total_deleted = 0
    last_patient_id = 0

    loop do
      batch_count, last_patient_id = prepare_batch(connection, last_patient_id)
      break if batch_count.zero?

      deleted = 0
      ActiveRecord::Base.transaction(requires_new: true) do
        truncate_temp_table(connection, TEMP_PERSONS)
        prepare_deletable_person_ids(connection)
        delete_relationships(connection)
        delete_person_name_codes(connection)
        delete_tables_with_column(
          connection,
          'person_id',
          TEMP_PERSONS,
          except: %w[person patient obs users]
        )
        deleted = delete_join(connection, 'person', 'person_id', TEMP_PERSONS)
      end
      total_deleted += deleted
      puts "Deleted #{total_deleted}/#{candidate_count} unshared person identity record(s)"
    end

    total_deleted
  end

  def verify_batch_still_eligible!(connection, batch_count)
    batch = quoted(connection, TEMP_BATCH)
    current_count = candidate_scope
                    .joins("INNER JOIN #{batch} hard_delete_batch ON hard_delete_batch.id = patient.patient_id")
                    .count
    return if current_count == batch_count

    raise "Candidate batch changed while cleanup was running " \
          "(expected #{batch_count}, still eligible #{current_count}); " \
          'no rows from this batch were deleted'
  end

  def prepare_related_ids(connection)
    [TEMP_ENCOUNTERS, TEMP_OBSERVATIONS, TEMP_ORDERS, TEMP_VISITS, TEMP_PERSONS].each do |table|
      truncate_temp_table(connection, table)
    end

    insert_ids(connection, TEMP_ENCOUNTERS, <<~SQL.squish)
      SELECT encounter.encounter_id
      FROM encounter
      INNER JOIN #{quoted(connection, TEMP_BATCH)} batch
        ON batch.id = encounter.patient_id
    SQL
    insert_ids(connection, TEMP_OBSERVATIONS, <<~SQL.squish)
      SELECT obs.obs_id
      FROM obs
      INNER JOIN #{quoted(connection, TEMP_BATCH)} batch
        ON batch.id = obs.person_id
    SQL
    insert_ids(connection, TEMP_OBSERVATIONS, <<~SQL.squish)
      SELECT obs.obs_id
      FROM obs
      INNER JOIN #{quoted(connection, TEMP_ENCOUNTERS)} target_encounter
        ON target_encounter.id = obs.encounter_id
    SQL
    insert_ids(connection, TEMP_ORDERS, <<~SQL.squish)
      SELECT orders.order_id
      FROM orders
      INNER JOIN #{quoted(connection, TEMP_BATCH)} batch
        ON batch.id = orders.patient_id
    SQL
    insert_ids(connection, TEMP_ORDERS, <<~SQL.squish)
      SELECT orders.order_id
      FROM orders
      INNER JOIN #{quoted(connection, TEMP_ENCOUNTERS)} target_encounter
        ON target_encounter.id = orders.encounter_id
    SQL
    insert_ids(connection, TEMP_VISITS, <<~SQL.squish)
      SELECT visit.visit_id
      FROM visit
      INNER JOIN #{quoted(connection, TEMP_BATCH)} batch
        ON batch.id = visit.patient_id
      WHERE NOT EXISTS (
        SELECT 1
        FROM encounter surviving_encounter
        LEFT JOIN #{quoted(connection, TEMP_ENCOUNTERS)} target_encounter
          ON target_encounter.id = surviving_encounter.encounter_id
        WHERE surviving_encounter.visit_id = visit.visit_id
          AND target_encounter.id IS NULL
      )
    SQL
  end

  # A merge can move encounters to the primary patient while preserving their
  # existing visit_id. In that case the visit is clinical data shared with the
  # surviving patient and must be transferred, not deleted with the secondary.
  def rehome_visits_with_surviving_encounters(connection)
    visits = connection.quote_table_name('visit')
    batch = quoted(connection, TEMP_BATCH)
    encounters = quoted(connection, TEMP_ENCOUNTERS)
    connection.execute(<<~SQL.squish)
      UPDATE #{visits} target_visit
      INNER JOIN #{batch} original_owner
        ON original_owner.id = target_visit.patient_id
      INNER JOIN (
        SELECT surviving_encounter.visit_id,
               MIN(surviving_encounter.patient_id) AS surviving_patient_id
        FROM encounter surviving_encounter
        LEFT JOIN #{encounters} target_encounter
          ON target_encounter.id = surviving_encounter.encounter_id
        WHERE surviving_encounter.visit_id IS NOT NULL
          AND target_encounter.id IS NULL
        GROUP BY surviving_encounter.visit_id
      ) surviving_visit
        ON surviving_visit.visit_id = target_visit.visit_id
      SET target_visit.patient_id = surviving_visit.surviving_patient_id
    SQL
  end

  def insert_ids(connection, table_name, select_sql)
    connection.execute(<<~SQL.squish)
      INSERT IGNORE INTO #{quoted(connection, table_name)} (id)
      #{select_sql}
    SQL
  end

  def break_circular_clinical_references(connection)
    observations = quoted(connection, TEMP_OBSERVATIONS)
    orders = quoted(connection, TEMP_ORDERS)

    connection.execute(<<~SQL.squish)
      UPDATE obs target
      INNER JOIN #{orders} target_order ON target.order_id = target_order.id
      SET target.order_id = NULL
    SQL
    connection.execute(<<~SQL.squish)
      UPDATE obs target
      INNER JOIN #{observations} target_observation ON target.obs_group_id = target_observation.id
      SET target.obs_group_id = NULL
    SQL
    connection.execute(<<~SQL.squish)
      UPDATE orders target
      INNER JOIN #{observations} target_observation ON target.obs_id = target_observation.id
      SET target.obs_id = NULL
    SQL
  end

  def delete_nonstandard_foreign_keys(connection)
    delete_join(connection, 'pharmacy_obs', 'dispensation_obs_id', TEMP_OBSERVATIONS)
  end

  def delete_nested_clinical_children(connection)
    observations = quoted(connection, TEMP_OBSERVATIONS)
    encounters = quoted(connection, TEMP_ENCOUNTERS)
    orders = quoted(connection, TEMP_ORDERS)

    if base_table_exists?(connection, 'notification_alert_recipient') &&
       base_table_exists?(connection, 'notification_alert')
      connection.execute(<<~SQL.squish)
        DELETE recipient
        FROM notification_alert_recipient recipient
        INNER JOIN notification_alert alert ON alert.alert_id = recipient.alert_id
        INNER JOIN #{orders} target_order ON target_order.id = alert.order_id
      SQL
    end

    if base_table_exists?(connection, 'concept_proposal_tag_map') &&
       base_table_exists?(connection, 'concept_proposal')
      connection.execute(<<~SQL.squish)
        DELETE tag_map
        FROM concept_proposal_tag_map tag_map
        INNER JOIN concept_proposal proposal
          ON proposal.concept_proposal_id = tag_map.concept_proposal_id
        LEFT JOIN #{observations} target_observation
          ON target_observation.id = proposal.obs_id
        LEFT JOIN #{encounters} target_encounter
          ON target_encounter.id = proposal.encounter_id
        WHERE target_observation.id IS NOT NULL OR target_encounter.id IS NOT NULL
      SQL
    end

    if base_table_exists?(connection, 'note')
      connection.execute(<<~SQL.squish)
        UPDATE note child
        INNER JOIN note target_note ON target_note.note_id = child.parent
        LEFT JOIN #{observations} target_observation
          ON target_observation.id = target_note.obs_id
        LEFT JOIN #{encounters} target_encounter
          ON target_encounter.id = target_note.encounter_id
        LEFT JOIN #{quoted(connection, TEMP_BATCH)} target_patient
          ON target_patient.id = target_note.patient_id
        SET child.parent = NULL
        WHERE target_patient.id IS NOT NULL
           OR target_observation.id IS NOT NULL
           OR target_encounter.id IS NOT NULL
      SQL
    end

    return unless base_table_exists?(connection, 'pharmacy_obs')

    connection.execute(<<~SQL.squish)
      UPDATE pharmacy_obs child
      INNER JOIN pharmacy_obs target_group
        ON target_group.pharmacy_module_id = child.obs_group_id
      INNER JOIN #{observations} target_observation
        ON target_observation.id = target_group.dispensation_obs_id
      SET child.obs_group_id = NULL
    SQL
  end

  def delete_merge_audits(connection)
    return unless base_table_exists?(connection, 'merge_audits')

    batch = quoted(connection, TEMP_BATCH)
    connection.execute(<<~SQL.squish)
      UPDATE merge_audits child
      INNER JOIN merge_audits target_merge
        ON target_merge.id = child.secondary_previous_merge_id
      INNER JOIN #{batch} matched_patient
        ON matched_patient.id = target_merge.primary_id
        OR matched_patient.id = target_merge.secondary_id
      SET child.secondary_previous_merge_id = NULL
    SQL
    connection.execute(<<~SQL.squish)
      DELETE target
      FROM merge_audits target
      INNER JOIN #{batch} matched_patient
        ON matched_patient.id = target.primary_id
        OR matched_patient.id = target.secondary_id
    SQL
  end

  def delete_patient_program_children(connection)
    return unless base_table_exists?(connection, 'patient_state') &&
                  base_table_exists?(connection, 'patient_program')

    batch = quoted(connection, TEMP_BATCH)
    connection.execute(<<~SQL.squish)
      DELETE state
      FROM patient_state state
      INNER JOIN patient_program program
        ON program.patient_program_id = state.patient_program_id
      INNER JOIN #{batch} target_patient
        ON target_patient.id = program.patient_id
    SQL
  end

  def delete_nonstandard_patient_references(connection)
    batch = quoted(connection, TEMP_BATCH)

    delete_when_any_column_matches(
      connection,
      'merged_patients',
      %w[patient_id merged_to_id],
      batch,
      transactional: true
    )
    delete_when_any_column_matches(
      connection,
      'patients_to_merge',
      %w[patient_id to_merge_to_id],
      batch,
      transactional: true
    )
    delete_when_any_column_matches(
      connection,
      'potential_duplicates',
      %w[patient_id_a patient_id_b],
      batch,
      transactional: true
    )
    delete_when_any_column_matches(
      connection,
      'visits',
      %w[patientId],
      batch,
      transactional: true
    )

    return unless base_table_exists?(connection, 'program_encounter_details') &&
                  base_table_exists?(connection, 'program_encounter')

    connection.execute(<<~SQL.squish)
      DELETE details
      FROM program_encounter_details details
      INNER JOIN program_encounter parent
        ON parent.program_encounter_id = details.program_encounter_id
      INNER JOIN #{batch} target_patient ON target_patient.id = parent.patient_id
    SQL
  end

  def delete_nontransactional_patient_references(connection)
    batch = quoted(connection, TEMP_BATCH)
    delete_when_any_column_matches(
      connection,
      'patients_to_merge',
      %w[patient_id to_merge_to_id],
      batch,
      transactional: false
    )
    delete_tables_with_column(
      connection,
      'patient_id',
      TEMP_BATCH,
      except: %w[patient encounter obs orders visit patients_to_merge],
      transactional: false
    )
  end

  def delete_when_any_column_matches(
    connection,
    table_name,
    column_names,
    quoted_id_table,
    transactional: nil
  )
    return unless base_table_exists?(connection, table_name)
    if !transactional.nil? && transactional_table?(connection, table_name) != transactional
      return
    end

    table = connection.quote_table_name(table_name)
    predicate = column_names.map do |column_name|
      column = connection.quote_column_name(column_name)
      "matched.id = target.#{column}"
    end.join(' OR ')
    connection.execute(<<~SQL.squish)
      DELETE target
      FROM #{table} target
      INNER JOIN #{quoted_id_table} matched ON #{predicate}
    SQL
  end

  def prepare_deletable_person_ids(connection)
    persons = quoted(connection, TEMP_PERSONS)
    batch = quoted(connection, TEMP_BATCH)
    connection.execute(<<~SQL.squish)
      INSERT IGNORE INTO #{persons} (id)
      SELECT batch.id
      FROM #{batch} batch
      WHERE NOT EXISTS (
        SELECT 1 FROM users
        WHERE users.person_id = batch.id
      )
        AND NOT EXISTS (
          SELECT 1 FROM encounter
          WHERE encounter.provider_id = batch.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM logic_rule_token
          WHERE logic_rule_token.creator = batch.id
             OR logic_rule_token.changed_by = batch.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM patient
          WHERE patient.patient_id = batch.id
        )
    SQL
  end

  def delete_relationships(connection)
    return unless base_table_exists?(connection, 'relationship')

    persons = quoted(connection, TEMP_PERSONS)
    connection.execute(<<~SQL.squish)
      DELETE target
      FROM relationship target
      INNER JOIN #{persons} matched_person
        ON matched_person.id = target.person_a
        OR matched_person.id = target.person_b
    SQL
  end

  def delete_person_name_codes(connection)
    return unless base_table_exists?(connection, 'person_name_code') &&
                  base_table_exists?(connection, 'person_name')

    persons = quoted(connection, TEMP_PERSONS)
    connection.execute(<<~SQL.squish)
      DELETE name_code
      FROM person_name_code name_code
      INNER JOIN person_name name
        ON name.person_name_id = name_code.person_name_id
      INNER JOIN #{persons} target_person ON target_person.id = name.person_id
    SQL
  end

  def delete_tables_with_column(
    connection,
    column_name,
    id_table,
    except:,
    transactional: true
  )
    base_tables_with_column(connection, column_name).each do |table_name|
      next if except.include?(table_name)
      next unless transactional_table?(connection, table_name) == transactional

      delete_join(connection, table_name, column_name, id_table)
    end
  end

  def base_tables_with_column(connection, column_name)
    @base_tables_with_column ||= {}
    @base_tables_with_column[column_name] ||= connection.select_values(<<~SQL.squish)
      SELECT columns.TABLE_NAME
      FROM information_schema.COLUMNS columns
      INNER JOIN information_schema.TABLES tables
        ON tables.TABLE_SCHEMA = columns.TABLE_SCHEMA
       AND tables.TABLE_NAME = columns.TABLE_NAME
      WHERE columns.TABLE_SCHEMA = DATABASE()
        AND columns.COLUMN_NAME = #{connection.quote(column_name)}
        AND tables.TABLE_TYPE = 'BASE TABLE'
    SQL
  end

  def base_table_exists?(connection, table_name)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = #{connection.quote(table_name)}
        AND TABLE_TYPE = 'BASE TABLE'
    SQL
  end

  def transactional_table?(connection, table_name)
    @table_engines ||= {}
    engine = @table_engines.fetch(table_name) do
      @table_engines[table_name] = connection.select_value(<<~SQL.squish)
        SELECT ENGINE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = #{connection.quote(table_name)}
          AND TABLE_TYPE = 'BASE TABLE'
      SQL
    end
    engine.to_s.casecmp('InnoDB').zero?
  end

  def delete_join(connection, table_name, column_name, id_table)
    table = connection.quote_table_name(table_name)
    column = connection.quote_column_name(column_name)
    ids = quoted(connection, id_table)
    connection.delete(<<~SQL.squish)
      DELETE target
      FROM #{table} target
      INNER JOIN #{ids} ids ON target.#{column} = ids.id
    SQL
  end

  def truncate_temp_table(connection, table_name)
    connection.execute("TRUNCATE TABLE #{quoted(connection, table_name)}")
  end

  def temp_count(connection, table_name)
    connection.select_value("SELECT COUNT(*) FROM #{quoted(connection, table_name)}").to_i
  end

  def quoted(connection, table_name)
    connection.quote_table_name(table_name)
  end

  def drop_temp_tables(connection)
    return unless connection

    TEMP_TABLES.reverse_each do |table_name|
      connection.execute("DROP TEMPORARY TABLE IF EXISTS #{quoted(connection, table_name)}")
    rescue StandardError => e
      Rails.logger.warn("Could not drop temporary hard-delete table #{table_name}: #{e.message}")
    end
  end
end
