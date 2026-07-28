# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'csv'

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

      backup_dir = backup_plan(plan)
      apply_plan(plan)
      enqueue_patient_sync(patient_id) if @enqueue_sync
      puts "  Applied. Backup: #{backup_dir}"
    end

    print_summary(totals)
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
    drug_fields = DRUG_ORDER_FIELDS.map do |field|
      "drug_order.#{field} AS cleanup_drug_#{field}"
    end

    Order.unscoped
         .where(patient_id: patient_id, voided: 0)
         .left_outer_joins(:drug_order)
         .select('orders.*', *drug_fields)
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

      scope.order(:obs_id).find_each(batch_size: @batch_size) do |observation|
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

  def backup_plan(plan)
    timestamp = Time.current.strftime('%Y%m%dT%H%M%S%6N')
    directory = Rails.root.join('tmp', 'duplicate_clinical_data_backups', "patient_#{plan.patient_id}_#{timestamp}")
    FileUtils.mkdir_p(directory, mode: 0o700)

    write_jsonl(directory.join('orders.jsonl'), Order.unscoped, :order_id, plan.duplicate_order_ids)
    write_jsonl(directory.join('drug_orders.jsonl'), DrugOrder.unscoped, :order_id, plan.duplicate_order_ids)
    write_jsonl(
      directory.join('observations.jsonl'),
      Observation.unscoped,
      :obs_id,
      plan.duplicate_observation_ids
    )

    manifest = {
      patient_id: plan.patient_id,
      mode: @mode,
      voided_by: @voided_by,
      created_at: Time.current.iso8601,
      duplicate_orders: plan.duplicate_order_ids.length,
      duplicate_observations: plan.duplicate_observation_ids.length,
      order_keeper_map: plan.order_duplicate_to_keeper,
      observation_keeper_map: plan.observation_duplicate_to_keeper
    }
    write_private_file(directory.join('manifest.json')) do |file|
      file.write(JSON.pretty_generate(manifest))
    end

    directory
  end

  def write_jsonl(path, scope, primary_key, ids)
    write_private_file(path) do |file|
      ids.each_slice(@batch_size) do |slice|
        scope.where(primary_key => slice).order(primary_key).each do |record|
          file.puts(record.attributes.to_json)
        end
      end
    end
  end

  def write_private_file(path)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      yield file
    end
  end

  def apply_plan(plan)
    return if plan.duplicate_order_ids.empty? && plan.duplicate_observation_ids.empty?

    now = Time.current

    ActiveRecord::Base.transaction do
      remap_foreign_keys(plan)
      void_rows(Observation.unscoped, :obs_id, plan.duplicate_observation_ids, now)
      void_rows(Order.unscoped, :order_id, plan.duplicate_order_ids, now)
    end
  end

  def remap_foreign_keys(plan)
    plan.order_duplicate_to_keeper.each_slice(@batch_size) do |slice|
      bulk_remap(
        table: Observation.table_name,
        primary_scope: "person_id = #{plan.patient_id.to_i} AND voided = 0",
        foreign_key: 'order_id',
        mapping: slice.to_h
      )
    end

    plan.observation_duplicate_to_keeper.each_slice(@batch_size) do |slice|
      mapping = slice.to_h
      bulk_remap(
        table: Observation.table_name,
        primary_scope: "person_id = #{plan.patient_id.to_i} AND voided = 0",
        foreign_key: 'obs_group_id',
        mapping: mapping
      )
      bulk_remap(
        table: Order.table_name,
        primary_scope: "patient_id = #{plan.patient_id.to_i} AND voided = 0",
        foreign_key: 'obs_id',
        mapping: mapping
      )
    end
  end

  def bulk_remap(table:, primary_scope:, foreign_key:, mapping:)
    return if mapping.empty?

    connection = ActiveRecord::Base.connection
    quoted_table = connection.quote_table_name(table)
    quoted_foreign_key = connection.quote_column_name(foreign_key)
    cases = mapping.map { |duplicate_id, keeper_id| "WHEN #{duplicate_id.to_i} THEN #{keeper_id.to_i}" }.join(' ')
    duplicate_ids = mapping.keys.map(&:to_i).join(',')

    connection.execute(<<~SQL.squish)
      UPDATE #{quoted_table}
      SET #{quoted_foreign_key} = CASE #{quoted_foreign_key} #{cases} ELSE #{quoted_foreign_key} END
      WHERE #{primary_scope}
        AND #{quoted_foreign_key} IN (#{duplicate_ids})
    SQL
  end

  def void_rows(scope, primary_key, ids, now)
    ids.each_slice(@batch_size) do |slice|
      scope.where(primary_key => slice, voided: 0).update_all(
        voided: 1,
        voided_by: @voided_by,
        date_voided: now,
        void_reason: VOID_REASON
      )
    end
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

namespace :clinical_data do
  desc 'Dry-run or void replay-created duplicate observations and orders for selected patients'
  task deduplicate: :environment do
    DeduplicatePatientClinicalDataTask.new.run
  end

  desc 'Export OPD patients with repeated semantic observations to CSV'
  task opd_duplicate_report: :environment do
    minimum_duplicates = [ENV.fetch('MIN_DUPLICATES', '1').to_i, 1].max
    output_path = ENV['OUTPUT'].presence ||
                  Rails.root.join('tmp', 'opd_duplicate_patient_ids.csv').to_s
    output_path = File.expand_path(output_path, Rails.root)
    FileUtils.mkdir_p(File.dirname(output_path))

    rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT person_id,
             SUM(group_count - 1) AS duplicate_observations,
             SUM(group_count) AS rows_in_duplicate_groups,
             MAX(group_count) AS largest_repeat,
             MIN(first_created) AS first_duplicate_group_created,
             MAX(last_created) AS last_duplicate_group_created
      FROM (
        SELECT o.person_id, o.encounter_id, o.concept_id, o.location_id,
               o.accession_number, o.comments, o.value_boolean, o.value_coded,
               o.value_coded_name_id, o.value_complex, o.value_datetime,
               o.value_drug, o.value_group_id, o.value_modifier, o.value_numeric,
               o.value_text, COUNT(*) AS group_count,
               MIN(o.date_created) AS first_created,
               MAX(o.date_created) AS last_created
        FROM obs o
        INNER JOIN encounter e ON e.encounter_id = o.encounter_id
        WHERE e.program_id = 14 AND e.voided = 0 AND o.voided = 0
        GROUP BY o.person_id, o.encounter_id, o.concept_id, o.location_id,
                 o.accession_number, o.comments, o.value_boolean, o.value_coded,
                 o.value_coded_name_id, o.value_complex, o.value_datetime,
                 o.value_drug, o.value_group_id, o.value_modifier, o.value_numeric,
                 o.value_text
        HAVING COUNT(*) > 1
      ) duplicate_groups
      GROUP BY person_id
      HAVING SUM(group_count - 1) >= #{minimum_duplicates}
      ORDER BY duplicate_observations DESC, person_id
    SQL

    CSV.open(output_path, 'w', write_headers: true, headers: %w[
      patient_id duplicate_observations rows_in_duplicate_groups largest_repeat
      first_duplicate_group_created last_duplicate_group_created severity
    ]) do |csv|
      rows.each do |row|
        duplicate_count = row['duplicate_observations'].to_i
        severity =
          if duplicate_count >= 1_000
            'critical'
          elsif duplicate_count >= 100
            'high'
          elsif duplicate_count >= 10
            'medium'
          else
            'low'
          end

        csv << [
          row['person_id'],
          duplicate_count,
          row['rows_in_duplicate_groups'],
          row['largest_repeat'],
          row['first_duplicate_group_created'],
          row['last_duplicate_group_created'],
          severity
        ]
      end
    end

    puts "Exported #{rows.length} OPD patient(s) to #{output_path}"
  end
end
