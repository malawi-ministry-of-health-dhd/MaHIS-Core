# frozen_string_literal: true

# Removes replay-created observation and order duplicates from the active
# clinical record. Rows are voided, not physically deleted, because obs/orders
# have audit and foreign-key relationships that must remain recoverable.
#
# Usage:
#   PATIENT_IDS=149550 bin/rails clinical_data:deduplicate
#   PATIENT_IDS=149550 MODE=exact bin/rails clinical_data:deduplicate
#   PATIENT_IDS=149550 MODE=replay bin/rails clinical_data:deduplicate
#   PATIENT_IDS=149550 MODE=replay APPLY=1 CONFIRM=VOID_DUPLICATES VOIDED_BY=1 \
#     bin/rails clinical_data:deduplicate
#
# Multiple patients:
#   PATIENT_IDS=149550,149556,149557 bin/rails clinical_data:deduplicate
#
# Parallel processing:
#   PATIENT_IDS=149550,149556,149557 MODE=replay APPLY=1 \
#     CONFIRM=VOID_DUPLICATES VOIDED_BY=1 ASYNC=1 \
#     bin/rails clinical_data:deduplicate
#
# MODE=clinical (default):
#   Treats identical values in the same encounter as duplicates even when
#   generated timestamps differ. This is intended for replay-corrupted records.
#
# MODE=exact:
#   Also includes clinical timestamps in the comparison. This only removes
#   literal semantic duplicates and may leave timestamp-varied replay data.
#
# MODE=replay:
#   Aggressive recovery for records known to have been replayed thousands of
#   times. Keeps the earliest order for each encounter/concept/drug and ignores
#   regenerated order ids while comparing observations. Generated "Drug end
#   date" observations are matched to the retained medication order, because a
#   replay creates both a new order id and a slightly different end timestamp.
#   Always review its dry run before applying.
class DeduplicatePatientClinicalDataTask
  CONFIRMATION = 'VOID_DUPLICATES'
  DEFAULT_BATCH_SIZE = 1_000
  VOID_REASON = 'Duplicate clinical data created by repeated payload processing'
  TEMP_ORDER_MAP = 'tmp_clinical_order_duplicate_map'
  TEMP_OBSERVATION_MAP = 'tmp_clinical_observation_duplicate_map'

  OBSERVATION_VALUE_FIELDS = %w[
    accession_number comments concept_id location_id value_boolean value_coded
    value_coded_name_id value_complex value_datetime value_drug value_group_id
    value_modifier value_numeric value_text
  ].freeze
  OBSERVATION_TIME_FIELDS = %w[obs_datetime date_started date_stopped].freeze

  ORDER_VALUE_FIELDS = %w[
    accession_number comment_to_fulfiller concept_id discontinued
    discontinued_reason discontinued_reason_non_coded encounter_id
    fulfiller_comment fulfiller_status instructions order_type_id orderer
  ].freeze
  ORDER_TIME_FIELDS = %w[start_date auto_expire_date discontinued_date].freeze
  DRUG_ORDER_FIELDS = %w[
    complex dose drug_inventory_id equivalent_daily_dose frequency prn quantity
    units
  ].freeze

  Plan = Struct.new(
    :patient_id,
    :order_duplicate_to_keeper,
    :observation_duplicate_to_keeper,
    :order_groups,
    :observation_groups,
    keyword_init: true
  ) do
    def duplicate_order_ids
      order_duplicate_to_keeper.keys
    end

    def duplicate_observation_ids
      observation_duplicate_to_keeper.keys
    end
  end

  def initialize(env = ENV)
    @patient_ids = parse_patient_ids(env['PATIENT_IDS'].presence || env['PATIENT_ID'].presence)
    @mode = env.fetch('MODE', 'clinical').to_s.downcase
    @apply = env['APPLY'].to_s == '1'
    @confirmation = env['CONFIRM'].to_s
    @voided_by = env['VOIDED_BY'].presence&.to_i
    @batch_size = positive_integer(env['BATCH_SIZE'], DEFAULT_BATCH_SIZE)
    @enqueue_sync = env.fetch('ENQUEUE_SYNC', '1').to_s != '0'

    validate_options!
  end

  def run
    print_header

    totals = {
      patients: 0,
      duplicate_order_groups: 0,
      duplicate_orders: 0,
      duplicate_observation_groups: 0,
      duplicate_observations: 0
    }

    @patient_ids.each do |patient_id|
      plan = build_plan(patient_id)
      print_plan(plan)
      add_to_totals(totals, plan)
      next unless @apply

      apply_plan(plan)
      enqueue_patient_sync(patient_id) if @enqueue_sync
      puts '  Applied.'
    end

    print_summary(totals)
  end

  def enqueue
    options = {
      'mode' => @mode,
      'apply' => @apply,
      'voided_by' => @voided_by,
      'batch_size' => @batch_size,
      'enqueue_sync' => @enqueue_sync
    }
    job_args = @patient_ids.map { |patient_id| [patient_id, options] }
    job_ids = ClinicalDataDeduplicationJob.perform_bulk(job_args)
    accepted = job_ids.compact.size

    puts "Queued #{accepted}/#{@patient_ids.size} patient cleanup job(s) on clinical_data_cleanup."
    if accepted < @patient_ids.size
      puts 'Some jobs were already queued or running and were rejected by the uniqueness lock.'
    end
    puts 'Run the dedicated worker with:'
    puts '  bundle exec sidekiq -C config/sidekiq_clinical_data_cleanup.yml'

    job_ids
  end

  private

  def parse_patient_ids(value)
    value.to_s.split(',').map(&:strip).reject(&:blank?).map do |patient_id|
      Integer(patient_id, 10)
    rescue ArgumentError
      raise ArgumentError, "Invalid patient id: #{patient_id.inspect}"
    end.uniq
  end

  def positive_integer(value, fallback)
    parsed = value.to_i
    parsed.positive? ? parsed : fallback
  end

  def validate_options!
    raise ArgumentError, 'PATIENT_IDS (or PATIENT_ID) is required' if @patient_ids.empty?
    unless %w[clinical exact replay].include?(@mode)
      raise ArgumentError, 'MODE must be clinical, exact, or replay'
    end

    missing = @patient_ids.reject { |patient_id| Patient.unscoped.exists?(patient_id: patient_id) }
    raise ArgumentError, "Patient(s) not found: #{missing.join(', ')}" if missing.any?

    return unless @apply

    unless @confirmation == CONFIRMATION
      raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required when APPLY=1"
    end
    raise ArgumentError, 'VOIDED_BY is required when APPLY=1' if @voided_by.blank?
    raise ArgumentError, "VOIDED_BY user #{@voided_by} was not found" unless User.unscoped.exists?(user_id: @voided_by)
  end

  def print_header
    puts "\n===== Duplicate Patient Clinical Data Cleanup ====="
    puts "Patients: #{@patient_ids.join(', ')}"
    puts "Mode: #{@mode}"
    puts "Action: #{@apply ? 'VOID DUPLICATES' : 'DRY RUN'}"
    puts "Batch size: #{@batch_size}"
    puts
  end

  def build_plan(patient_id)
    order_map, order_groups = plan_orders(patient_id)
    observation_map, observation_groups = plan_observations(patient_id, order_map)

    Plan.new(
      patient_id: patient_id,
      order_duplicate_to_keeper: order_map,
      observation_duplicate_to_keeper: observation_map,
      order_groups: order_groups,
      observation_groups: observation_groups
    )
  end

  def plan_orders(patient_id)
    seen = {}
    duplicate_to_keeper = {}
    duplicate_group_keys = {}

    order_scope(patient_id).find_each(batch_size: @batch_size) do |order|
      key = order_key(order)
      keeper_id = seen[key]

      if keeper_id
        duplicate_to_keeper[order.order_id] = keeper_id
        duplicate_group_keys[key] = true
      else
        seen[key] = order.order_id
      end
    end

    [duplicate_to_keeper, duplicate_group_keys.length]
  end

  def order_scope(patient_id)
    order_fields =
      if @mode == 'replay'
        %w[order_id encounter_id order_type_id concept_id]
      else
        %w[order_id] + ORDER_VALUE_FIELDS + ORDER_TIME_FIELDS
      end
    drug_field_names = @mode == 'replay' ? %w[drug_inventory_id] : DRUG_ORDER_FIELDS
    drug_fields = drug_field_names.map do |field|
      "drug_order.#{field} AS cleanup_drug_#{field}"
    end

    Order.unscoped
         .where(patient_id: patient_id, voided: 0)
         .left_outer_joins(:drug_order)
         .select(*order_fields.uniq.map { |field| "orders.#{field}" }, *drug_fields)
         .order(:order_id)
  end

  def order_key(order)
    if @mode == 'replay'
      return [
        order.encounter_id,
        order.order_type_id,
        order.concept_id,
        normalized_value(order['cleanup_drug_drug_inventory_id'])
      ].freeze
    end

    fields = ORDER_VALUE_FIELDS.dup
    fields.concat(ORDER_TIME_FIELDS) if @mode == 'exact'

    [
      *fields.map { |field| normalized_value(order[field]) },
      *DRUG_ORDER_FIELDS.map { |field| normalized_value(order["cleanup_drug_#{field}"]) }
    ].freeze
  end

  def plan_observations(patient_id, order_map)
    seen = {}
    duplicate_to_keeper = {}
    duplicate_group_keys = {}

    # Parents are planned first so child observations can use the retained
    # parent id in their comparison key.
    [nil, :children].each do |pass|
      scope = Observation.unscoped.where(person_id: patient_id, voided: 0)
      scope = pass.nil? ? scope.where(obs_group_id: nil) : scope.where.not(obs_group_id: nil)
      fields = %w[obs_id encounter_id obs_group_id order_id concept_id] + OBSERVATION_VALUE_FIELDS
      fields.concat(OBSERVATION_TIME_FIELDS) if @mode == 'exact'

      scope.select(*fields.uniq.map { |field| "obs.#{field}" })
           .order(:obs_id)
           .find_each(batch_size: @batch_size) do |observation|
        key = observation_key(observation, order_map, duplicate_to_keeper)
        keeper_id = seen[key]

        if keeper_id
          duplicate_to_keeper[observation.obs_id] = keeper_id
          duplicate_group_keys[key] = true
        else
          seen[key] = observation.obs_id
        end
      end
    end

    [duplicate_to_keeper, duplicate_group_keys.length]
  end

  def observation_key(observation, order_map, observation_map)
    if @mode == 'replay' && observation.concept_id == drug_end_date_concept_id
      return [
        :replay_drug_end_date,
        observation.encounter_id,
        observation.concept_id,
        resolve_keeper(observation.order_id, order_map)
      ].freeze
    end

    fields = OBSERVATION_VALUE_FIELDS.dup
    fields.concat(OBSERVATION_TIME_FIELDS) if @mode == 'exact'

    normalized_parent_id = resolve_keeper(observation.obs_group_id, observation_map)
    normalized_order_id =
      resolve_keeper(observation.order_id, order_map) unless @mode == 'replay'

    [
      observation.encounter_id,
      normalized_parent_id,
      normalized_order_id,
      *fields.map { |field| normalized_value(observation[field]) }
    ].freeze
  end

  def drug_end_date_concept_id
    @drug_end_date_concept_id ||=
      ConceptName.unscoped.where(name: 'Drug end date', voided: 0).order(:concept_name_id).pick(:concept_id)
  end

  def resolve_keeper(id, mapping)
    return nil if id.blank?

    current_id = id
    visited = {}
    while mapping[current_id] && !visited[current_id]
      visited[current_id] = true
      current_id = mapping[current_id]
    end
    current_id
  end

  def normalized_value(value)
    case value
    when Time, DateTime
      value.iso8601(6)
    when BigDecimal
      value.to_s('F')
    else
      value
    end
  end

  def print_plan(plan)
    active_orders = Order.unscoped.where(patient_id: plan.patient_id, voided: 0).count
    active_observations = Observation.unscoped.where(person_id: plan.patient_id, voided: 0).count

    puts "Patient #{plan.patient_id}:"
    puts "  Orders: #{active_orders} active; #{plan.duplicate_order_ids.length} duplicate(s) in #{plan.order_groups} group(s)"
    puts "  Observations: #{active_observations} active; #{plan.duplicate_observation_ids.length} duplicate(s) in #{plan.observation_groups} group(s)"
    puts "  Would retain: #{active_orders - plan.duplicate_order_ids.length} orders, " \
         "#{active_observations - plan.duplicate_observation_ids.length} observations"
  end

  def add_to_totals(totals, plan)
    totals[:patients] += 1
    totals[:duplicate_order_groups] += plan.order_groups
    totals[:duplicate_orders] += plan.duplicate_order_ids.length
    totals[:duplicate_observation_groups] += plan.observation_groups
    totals[:duplicate_observations] += plan.duplicate_observation_ids.length
  end

  def apply_plan(plan)
    return if plan.duplicate_order_ids.empty? && plan.duplicate_observation_ids.empty?

    connection = ActiveRecord::Base.connection
    now = Time.current
    create_mapping_table(connection, TEMP_ORDER_MAP, plan.order_duplicate_to_keeper)
    create_mapping_table(connection, TEMP_OBSERVATION_MAP, plan.observation_duplicate_to_keeper)

    ActiveRecord::Base.transaction do
      remap_foreign_keys(connection, plan)
      void_from_mapping(
        connection,
        table: Observation.table_name,
        primary_key: 'obs_id',
        mapping_table: TEMP_OBSERVATION_MAP,
        primary_scope: "target.person_id = #{plan.patient_id.to_i}",
        now: now
      ) if plan.observation_duplicate_to_keeper.any?
      void_from_mapping(
        connection,
        table: Order.table_name,
        primary_key: 'order_id',
        mapping_table: TEMP_ORDER_MAP,
        primary_scope: "target.patient_id = #{plan.patient_id.to_i}",
        now: now
      ) if plan.order_duplicate_to_keeper.any?
    end
  ensure
    drop_mapping_table(connection, TEMP_ORDER_MAP) if connection
    drop_mapping_table(connection, TEMP_OBSERVATION_MAP) if connection
  end

  def create_mapping_table(connection, table_name, mapping)
    return if mapping.empty?

    quoted_table = connection.quote_table_name(table_name)
    connection.execute("DROP TEMPORARY TABLE IF EXISTS #{quoted_table}")
    connection.execute(<<~SQL.squish)
      CREATE TEMPORARY TABLE #{quoted_table} (
        duplicate_id BIGINT NOT NULL PRIMARY KEY,
        keeper_id BIGINT NOT NULL
      ) ENGINE=InnoDB
    SQL

    mapping.each_slice(@batch_size) do |slice|
      values = slice.map do |duplicate_id, keeper_id|
        "(#{duplicate_id.to_i},#{keeper_id.to_i})"
      end.join(',')
      connection.execute(
        "INSERT INTO #{quoted_table} (duplicate_id, keeper_id) VALUES #{values}"
      )
    end
  end

  def drop_mapping_table(connection, table_name)
    quoted_table = connection.quote_table_name(table_name)
    connection.execute("DROP TEMPORARY TABLE IF EXISTS #{quoted_table}")
  rescue StandardError => e
    Rails.logger.warn("Could not drop temporary cleanup table #{table_name}: #{e.message}")
  end

  def remap_foreign_keys(connection, plan)
    if plan.order_duplicate_to_keeper.any?
      remap_from_mapping(
        connection,
        table: Observation.table_name,
        foreign_key: 'order_id',
        mapping_table: TEMP_ORDER_MAP,
        primary_scope: "target.person_id = #{plan.patient_id.to_i}"
      )
    end

    if plan.observation_duplicate_to_keeper.any?
      remap_from_mapping(
        connection,
        table: Observation.table_name,
        foreign_key: 'obs_group_id',
        mapping_table: TEMP_OBSERVATION_MAP,
        primary_scope: "target.person_id = #{plan.patient_id.to_i}"
      )
      remap_from_mapping(
        connection,
        table: Order.table_name,
        foreign_key: 'obs_id',
        mapping_table: TEMP_OBSERVATION_MAP,
        primary_scope: "target.patient_id = #{plan.patient_id.to_i}"
      )
    end
  end

  def remap_from_mapping(connection, table:, foreign_key:, mapping_table:, primary_scope:)
    quoted_table = connection.quote_table_name(table)
    quoted_mapping_table = connection.quote_table_name(mapping_table)
    quoted_foreign_key = connection.quote_column_name(foreign_key)

    connection.execute(<<~SQL.squish)
      UPDATE #{quoted_table} target
      INNER JOIN #{quoted_mapping_table} duplicate_map
        ON target.#{quoted_foreign_key} = duplicate_map.duplicate_id
      SET target.#{quoted_foreign_key} = duplicate_map.keeper_id
      WHERE #{primary_scope} AND target.voided = 0
    SQL
  end

  def void_from_mapping(connection, table:, primary_key:, mapping_table:, primary_scope:, now:)
    quoted_table = connection.quote_table_name(table)
    quoted_mapping_table = connection.quote_table_name(mapping_table)
    quoted_primary_key = connection.quote_column_name(primary_key)
    quoted_time = connection.quote(now)
    quoted_reason = connection.quote(VOID_REASON)

    connection.execute(<<~SQL.squish)
      UPDATE #{quoted_table} target
      INNER JOIN #{quoted_mapping_table} duplicate_map
        ON target.#{quoted_primary_key} = duplicate_map.duplicate_id
      SET target.voided = 1,
          target.voided_by = #{@voided_by.to_i},
          target.date_voided = #{quoted_time},
          target.void_reason = #{quoted_reason}
      WHERE #{primary_scope} AND target.voided = 0
    SQL
  end

  def enqueue_patient_sync(patient_id)
    jid = Sync::BulkPatientRecordSyncJob.perform_async([patient_id], { 'location_id' => nil })
    puts "  Queued patient document rebuild: #{jid}"
  end

  def print_summary(totals)
    puts "\n===== Cleanup Summary ====="
    puts "Patients checked: #{totals[:patients]}"
    puts "Duplicate order groups: #{totals[:duplicate_order_groups]}"
    puts "Duplicate orders: #{totals[:duplicate_orders]}"
    puts "Duplicate observation groups: #{totals[:duplicate_observation_groups]}"
    puts "Duplicate observations: #{totals[:duplicate_observations]}"

    if @apply
      puts 'Changes applied. Duplicate rows were voided and remain recoverable.'
    else
      puts "\nDry run only; no records were changed."
      puts "Apply with: APPLY=1 CONFIRM=#{CONFIRMATION} VOIDED_BY=<user_id>"
    end
  end
end
