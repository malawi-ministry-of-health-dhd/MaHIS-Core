#!/usr/bin/env ruby
#
# Usage:
#   SOURCE_DB=mahis_pro TARGET_DB=mahis_dev bundle exec ruby bin/mahis_pro_to_dev_migrator.rb
#   SOURCE_DB=mahis_pro TARGET_DB=mahis_dev bundle exec ruby bin/mahis_pro_to_dev_migrator.rb --generate-concept-map-only
#   SOURCE_DB=mahis_pro TARGET_DB=mahis_dev bundle exec ruby bin/mahis_pro_to_dev_migrator.rb --used-unmatched-concepts-only
#   SOURCE_DB=mahis_pro TARGET_DB=mahis_dev bundle exec ruby bin/mahis_pro_to_dev_migrator.rb --backfill-only
#
# Optional:
#   REFRESH_CONCEPT_MAPPING=true  Regenerate the concept map before migrating.
#   DRY_RUN=true                  Verify connections and concept mapping without inserting rows.
#   TARGET_LOCATION_ID=123        Fallback location_id when a source location code cannot be mapped.
#   PRESERVE_LOCATION_IDS=true    Keep source location_id values as-is.
#   LOCATION_ATTRIBUTE_TYPE_NAME  Target location_attribute_type name used for facility codes.

require_relative '../config/environment' unless defined?(Rails)

require 'active_record'
require 'json'
require 'psych'
require 'set'
require 'time'

unless defined?(Form)
  class Form < ApplicationRecord
    self.table_name = 'form'
    self.primary_key = 'form_id'
  end
end

module MahisProToDevMigrator
  module_function

  SOURCE_DB = ENV.fetch('SOURCE_DB', 'mahis_pro')
  TARGET_DB = ENV.fetch('TARGET_DB', 'mahis_moses')
  BATCH_SIZE = ENV.fetch('BATCH_SIZE', '10000').to_i
  REFRESH_CONCEPT_MAPPING = ENV.fetch('REFRESH_CONCEPT_MAPPING', 'false') == 'true'
  GENERATE_CONCEPT_MAPPING_ONLY = ARGV.include?('--generate-concept-map-only')
  REPORT_USED_UNMATCHED_CONCEPTS_ONLY = ARGV.include?('--used-unmatched-concepts-only')
  BACKFILL_ONLY = ARGV.include?('--backfill-only')
  DRY_RUN = ENV.fetch('DRY_RUN', 'false') == 'true'
  PRESERVE_LOCATION_IDS = ENV.fetch('PRESERVE_LOCATION_IDS', 'false') == 'true'
  LOCATION_ATTRIBUTE_TYPE_NAME = ENV.fetch('LOCATION_ATTRIBUTE_TYPE_NAME', 'Facility Code')

  CONCEPT_MAPPING_FILE = Rails.root.join('db', 'mahis_pro_to_dev_concept_id_mapping.json')
  UNMATCHED_CONCEPTS_FILE = Rails.root.join('db', 'mahis_pro_to_dev_unmatched_concepts.json')
  USED_UNMATCHED_CONCEPTS_FILE = Rails.root.join('db', 'mahis_pro_to_dev_used_unmatched_concepts.json')
  CONCEPT_NAME_ALIASES_FILE = Rails.root.join('db', 'mahis_pro_to_dev_concept_name_aliases.json')
  SKIPPED_RECORDS_FILE = Rails.root.join('log', "mahis_pro_to_dev_skipped_records_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")

  USER_ID_CACHE = {}
  MIGRATED_USER_ID_CACHE = {}
  PERSON_ID_CACHE = {}
  ENCOUNTER_ID_CACHE = {}
  ORDER_ID_CACHE = {}
  OBS_ID_CACHE = {}
  PATIENT_PROGRAM_ID_CACHE = {}
  REPORT_DESIGN_ID_CACHE = {}
  STOCK_VERIFICATION_ID_CACHE = {}
  LOCATION_ID_CACHE = {}
  SOURCE_USER_LOCATION_CODE_CACHE = {}
  NAME_ID_CACHE = Hash.new { |hash, key| hash[key] = {} }

  SKIPPED_RECORDS = Hash.new { |hash, key| hash[key] = [] }
  UNMAPPED_LOCATION_CODES = Hash.new(0)

  OPTIONAL_CONCEPT_FIELDS = %i[value_coded discontinued_reason cause_of_death].freeze
  LOCATION_TABLE_MODELS = %w[
    User PatientIdentifier PatientProgram Encounter Observation PharmacyBatch PharmacyBatchItemReallocation
  ].freeze
  NON_RESET_MODELS = %w[
    Patient DrugOrder GlobalProperty UserRole UserProperty LimsAcknowledgementStatus Pharmacies PharmacyBatch PharmacyBatchItem
    PharmacyBatchItemReallocation PharmacyBatchVvm PharmacyStockBalance PharmacyStockVerification Pharmacy
  ].freeze
  BUILT_IN_CONCEPT_NAME_ALIASES = {
    'Does the family have a history of hypertension?' => 'Family History Hypertension',
    '+/- Fever' => 'Fever',
    'Diabetes family history' => 'Family History Diabetes Mellitus'
  }.freeze
  BUILT_IN_CONCEPT_ID_MAPPINGS = {
    30 => 47_624, # HIV pos
    5964 => 155 # TB
  }.freeze
  FIXED_SOURCE_LOCATION_CODE_MAPPINGS = {
    '272' => 'SA090626',
    '622' => 'SA091312',
    '398' => 'MC011864',
    '399' => 'MC010898'
  }.freeze

  def run
    migration_started_at = Time.now

    establish_target_connection!
    verify_databases!
    ensure_runtime_context!
    ensure_concept_mapping!

    if GENERATE_CONCEPT_MAPPING_ONLY
      puts 'Concept mapping generated. Migration was not run because --generate-concept-map-only was supplied.'
      return
    end

    if REPORT_USED_UNMATCHED_CONCEPTS_ONLY
      write_used_unmatched_concepts_report
      return
    end

    if BACKFILL_ONLY
      backfill_orders_obs_ids
      update_group_obs_ids
      puts "\nBackfill-only run complete in #{format_duration(Time.now - migration_started_at)}."
      return
    end

    if DRY_RUN
      puts 'DRY_RUN=true: mapping was prepared and database connectivity was verified. No rows will be inserted.'
      return
    end

    migrate_users
    migrate_user_access_and_configuration
    migration_groups.each_with_index do |group, index|
      group_started_at = Time.now
      group_inserted = 0
      group_processed = 0

      puts "\n#{'=' * 80}"
      puts "Migrating group #{index + 1}/#{migration_groups.length}"
      puts '=' * 80
      group.each do |table_name, model, dependencies|
        stats = populate_records(table_name, model, dependencies)
        group_inserted += stats[:inserted]
        group_processed += stats[:source_processed]
      end
      puts "Completed group #{index + 1}/#{migration_groups.length} in #{format_duration(Time.now - group_started_at)} " \
           "(source processed #{group_processed}, inserted #{group_inserted})"
    end

    backfill_orders_obs_ids
    update_group_obs_ids
    write_skipped_records_report
    puts "\nMigration complete in #{format_duration(Time.now - migration_started_at)}."
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end

  def establish_target_connection!
    database_config = Psych.load(File.read(Rails.root.join('config', 'database.yml')), aliases: true)
    env_config = database_config.fetch(Rails.env) { database_config.fetch('development') }
    target_config = env_config.merge('database' => TARGET_DB, 'pool' => ENV.fetch('RAILS_MAX_THREADS', 20).to_i + 5)

    ActiveRecord::Base.establish_connection(target_config)
    puts "Connected target ActiveRecord models to #{TARGET_DB}."
  end

  def verify_databases!
    [SOURCE_DB, TARGET_DB].each do |database|
      exists = ActiveRecord::Base.connection.select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM information_schema.SCHEMATA
        WHERE SCHEMA_NAME = #{quote(database)}
      SQL
      raise "Database #{database} was not found on this MySQL server." if exists.zero?
    end

    puts "Verified source #{SOURCE_DB} and target #{TARGET_DB} databases."
  end

  def ensure_runtime_context!
    target_location = target_location_id
    if PRESERVE_LOCATION_IDS
      puts 'Preserving source location_id values (PRESERVE_LOCATION_IDS=true).'
    else
      puts "Location mapping enabled: source location codes -> #{TARGET_DB}.location_attribute.value_reference."
      puts "Using fallback TARGET_LOCATION_ID=#{target_location} for unmapped locations." if target_location
    end

    current_user = User.unscoped.first
    if current_user
      current_user.location_id = target_location if target_location && current_user.respond_to?(:location_id=)
      User.current = current_user if User.respond_to?(:current=)
    end
  end

  def target_location_id
    return @target_location_id if defined?(@target_location_id)
    return @target_location_id = ENV['TARGET_LOCATION_ID'].to_i if ENV['TARGET_LOCATION_ID'].to_i.positive?
    return @target_location_id = nil unless table_exists?(TARGET_DB, 'global_property')

    property_value = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT property_value
      FROM #{table_ref(TARGET_DB, 'global_property')}
      WHERE property = 'current_health_center_id'
      LIMIT 1
    SQL

    @target_location_id = property_value.to_i.positive? ? property_value.to_i : nil
  rescue StandardError
    @target_location_id = nil
  end

  def ensure_concept_mapping!
    if REFRESH_CONCEPT_MAPPING || !usable_concept_mapping_file?
      puts 'Generating pro-to-dev concept mapping...'
      generate_concept_mapping!
    else
      puts "Loading concept mapping from #{CONCEPT_MAPPING_FILE}..."
      load_concept_mapping!
    end
  end

  def usable_concept_mapping_file?
    return false unless File.exist?(CONCEPT_MAPPING_FILE)

    data = JSON.parse(File.read(CONCEPT_MAPPING_FILE))
    data['source_database'] == SOURCE_DB &&
      data['destination_database'] == TARGET_DB &&
      data['mapping'].is_a?(Hash) &&
      data['mapping'].any?
  rescue JSON::ParserError
    false
  end

  def generate_concept_mapping!
    source_concepts = concepts_by_id(SOURCE_DB)
    destination_name_index = destination_concept_name_index
    destination_uuid_index = destination_concept_uuid_index
    name_aliases = concept_name_aliases

    mapping = {}
    unmatched = []

    source_concepts.each do |source_concept_id, source_concept|
      destination_concept_id = destination_uuid_index[source_concept[:uuid]]

      if destination_concept_id.nil?
        source_concept[:normalized_names].each do |normalized_name|
          destination_concept_id = destination_name_index[normalized_name]
          break if destination_concept_id
        end
      end

      if destination_concept_id.nil?
        source_concept[:normalized_names].each do |normalized_name|
          alias_name = name_aliases[normalized_name]
          destination_concept_id = destination_name_index[alias_name] if alias_name
          break if destination_concept_id
        end
      end

      if destination_concept_id
        mapping[source_concept_id.to_s] = destination_concept_id
      else
        unmatched << {
          concept_id: source_concept_id,
          name: source_concept[:preferred_name]
        }
      end
    end

    apply_builtin_concept_id_mappings!(mapping, unmatched, source_concepts)

    payload = {
      generated_at: Time.now.iso8601,
      source_database: SOURCE_DB,
      destination_database: TARGET_DB,
      total_source_concepts: source_concepts.length,
      total_dest_concepts: destination_concept_count,
      matched_concepts: mapping.length,
      unmatched_concepts: unmatched.length,
      mapping: mapping.sort_by { |source_id, _| source_id.to_i }.to_h
    }

    File.write(CONCEPT_MAPPING_FILE, JSON.pretty_generate(payload))
    File.write(UNMATCHED_CONCEPTS_FILE, JSON.pretty_generate(unmatched.sort_by { |row| row[:concept_id] }))

    @concept_id_map = mapping.transform_keys(&:to_i).transform_values(&:to_i)

    puts "Wrote #{mapping.length} concept mappings to #{CONCEPT_MAPPING_FILE}."
    puts "Wrote #{unmatched.length} unmatched concepts to #{UNMATCHED_CONCEPTS_FILE}."
  end

  def load_concept_mapping!
    payload = JSON.parse(File.read(CONCEPT_MAPPING_FILE))
    @concept_id_map = payload.fetch('mapping').transform_keys(&:to_i).transform_values(&:to_i)
    @concept_id_map.merge!(BUILT_IN_CONCEPT_ID_MAPPINGS)
    puts "Loaded #{@concept_id_map.length} concept mappings."
  end

  def apply_builtin_concept_id_mappings!(mapping, unmatched, source_concepts)
    BUILT_IN_CONCEPT_ID_MAPPINGS.each do |source_concept_id, destination_concept_id|
      next unless source_concepts.key?(source_concept_id)

      mapping[source_concept_id.to_s] = destination_concept_id
    end

    unmatched.reject! { |row| mapping.key?(row[:concept_id].to_s) }
  end

  def concept_name_aliases
    file_aliases = File.exist?(CONCEPT_NAME_ALIASES_FILE) ? JSON.parse(File.read(CONCEPT_NAME_ALIASES_FILE)) : {}

    BUILT_IN_CONCEPT_NAME_ALIASES.merge(file_aliases).each_with_object({}) do |(source_name, destination_name), aliases|
      aliases[normalize_name(source_name)] = normalize_name(destination_name)
    end
  end

  def write_used_unmatched_concepts_report
    unmatched = unmatched_concepts_by_id
    return puts "No unmatched concept file found at #{UNMATCHED_CONCEPTS_FILE}." if unmatched.empty?

    usage = unmatched.keys.each_with_object({}) { |concept_id, hash| hash[concept_id] = [] }
    direct_concept_usage_checks.each do |table_name, column_name|
      next unless table_exists?(SOURCE_DB, table_name) && column_names(SOURCE_DB, table_name).include?(column_name)

      concept_usage_counts(table_name, column_name, unmatched.keys).each do |concept_id, count|
        usage[concept_id] << {
          table: table_name,
          column: column_name,
          count: count
        }
      end
    end

    patient_state_concept_usage_counts(unmatched.keys).each do |concept_id, count|
      usage[concept_id] << {
        table: 'patient_state',
        column: 'state -> program_workflow_state.concept_id',
        count: count
      }
    end

    used_unmatched = usage.filter_map do |concept_id, locations|
      next if locations.empty?

      {
        concept_id: concept_id,
        name: unmatched[concept_id],
        total_usage_count: locations.sum { |location| location[:count] },
        used_in: locations
      }
    end.sort_by { |row| row[:concept_id] }

    File.write(USED_UNMATCHED_CONCEPTS_FILE, JSON.pretty_generate(used_unmatched))
    puts "Wrote #{used_unmatched.length} used unmatched concepts to #{USED_UNMATCHED_CONCEPTS_FILE}."
  end

  def unmatched_concepts_by_id
    return {} unless File.exist?(UNMATCHED_CONCEPTS_FILE)

    JSON.parse(File.read(UNMATCHED_CONCEPTS_FILE)).each_with_object({}) do |row, hash|
      hash[row.fetch('concept_id').to_i] = row.fetch('name')
    end
  end

  def direct_concept_usage_checks
    [
      ['person', 'cause_of_death'],
      ['orders', 'concept_id'],
      ['orders', 'discontinued_reason'],
      ['obs', 'concept_id'],
      ['obs', 'value_coded'],
      ['lims_acknowledgement_statuses', 'test']
    ]
  end

  def concept_usage_counts(table_name, column_name, concept_ids)
    return {} if concept_ids.empty?

    ActiveRecord::Base.connection.select_all(<<~SQL).to_a.each_with_object({}) do |row, hash|
      SELECT #{q(column_name)} AS concept_id, COUNT(*) AS usage_count
      FROM #{table_ref(SOURCE_DB, table_name)}
      WHERE #{q(column_name)} IN (#{concept_ids.join(',')})
      GROUP BY #{q(column_name)}
    SQL
      hash[row['concept_id'].to_i] = row['usage_count'].to_i
    end
  end

  def patient_state_concept_usage_counts(concept_ids)
    return {} if concept_ids.empty?
    return {} unless table_exists?(SOURCE_DB, 'patient_state') && table_exists?(SOURCE_DB, 'program_workflow_state')

    ActiveRecord::Base.connection.select_all(<<~SQL).to_a.each_with_object({}) do |row, hash|
      SELECT pws.concept_id AS concept_id, COUNT(*) AS usage_count
      FROM #{table_ref(SOURCE_DB, 'patient_state')} ps
      INNER JOIN #{table_ref(SOURCE_DB, 'program_workflow_state')} pws
        ON pws.program_workflow_state_id = ps.state
      WHERE pws.concept_id IN (#{concept_ids.join(',')})
      GROUP BY pws.concept_id
    SQL
      hash[row['concept_id'].to_i] = row['usage_count'].to_i
    end
  end

  def concept_id_map
    @concept_id_map ||= {}
  end

  def concepts_by_id(database)
    rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT
        c.concept_id,
        c.uuid,
        cn.name,
        cn.concept_name_type,
        cn.locale_preferred,
        cn.voided
      FROM #{table_ref(database, 'concept')} c
      LEFT JOIN #{table_ref(database, 'concept_name')} cn
        ON cn.concept_id = c.concept_id
       AND cn.voided = 0
      WHERE COALESCE(c.retired, 0) = 0
      ORDER BY c.concept_id, cn.locale_preferred DESC, cn.concept_name_type = 'FULLY_SPECIFIED' DESC, cn.name
    SQL

    rows.each_with_object({}) do |row, concepts|
      concept_id = row['concept_id'].to_i
      concepts[concept_id] ||= {
        uuid: row['uuid'],
        preferred_name: nil,
        normalized_names: []
      }

      name = row['name'].to_s.strip
      next if name.empty?

      concepts[concept_id][:preferred_name] ||= name
      normalized_name = normalize_name(name)
      concepts[concept_id][:normalized_names] << normalized_name unless concepts[concept_id][:normalized_names].include?(normalized_name)
    end
  end

  def destination_concept_name_index
    rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT
        c.concept_id,
        cn.name,
        cn.concept_name_type,
        cn.locale_preferred
      FROM #{table_ref(TARGET_DB, 'concept')} c
      INNER JOIN #{table_ref(TARGET_DB, 'concept_name')} cn
        ON cn.concept_id = c.concept_id
       AND cn.voided = 0
      WHERE COALESCE(c.retired, 0) = 0
      ORDER BY cn.locale_preferred DESC, cn.concept_name_type = 'FULLY_SPECIFIED' DESC, c.concept_id
    SQL

    rows.each_with_object({}) do |row, index|
      normalized_name = normalize_name(row['name'])
      next if normalized_name.empty?

      index[normalized_name] ||= row['concept_id'].to_i
    end
  end

  def destination_concept_uuid_index
    rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT concept_id, uuid
      FROM #{table_ref(TARGET_DB, 'concept')}
      WHERE uuid IS NOT NULL
    SQL

    rows.each_with_object({}) do |row, index|
      index[row['uuid']] = row['concept_id'].to_i if row['uuid'].present?
    end
  end

  def destination_concept_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table_ref(TARGET_DB, 'concept')}").to_i
  end

  def normalize_name(name)
    name.to_s.downcase.gsub(/\s+/, ' ').strip
  end

  def format_duration(seconds)
    seconds = seconds.to_f
    return "#{seconds.round(2)}s" if seconds < 60

    minutes = (seconds / 60).floor
    remaining_seconds = (seconds % 60).round
    return "#{minutes}m #{remaining_seconds}s" if minutes < 60

    hours = (minutes / 60).floor
    remaining_minutes = minutes % 60
    "#{hours}h #{remaining_minutes}m #{remaining_seconds}s"
  end

  def migrate_users
    return skip_table_message('users', 'source or target table does not exist') unless migratable_table?('users', User)

    puts "\nMigrating users..."
    admin_user = select_source_rows('users', "user_id = 1", nil, nil, User).first
    target_admin_id = User.unscoped.minimum(:user_id) || 1

    if admin_user && !User.unscoped.exists?(uuid: admin_user['uuid'])
      admin_user.symbolize_keys!
      admin_user = rewrite_location_ids([admin_user], User).first
      admin_user[:user_id] = nil
      admin_user[:person_id] = create_or_find_person(admin_user[:person_id])
      admin_user[:creator] = target_admin_id
      admin_user[:changed_by] = target_admin_id if admin_user.key?(:changed_by)
      insert_records(User, [admin_user])
    end

    populate_records('users', User, {
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      retired_by: :get_new_user_ids,
      person_id: :create_users_persons
    }, reset_primary_key: true)
  end

  def migrate_user_access_and_configuration
    populate_records('global_property', GlobalProperty, {}, reset_primary_key: false)
    populate_records('user_role', UserRole, {
      user_id: :get_migrated_user_ids
    }, reset_primary_key: false)
    populate_records('user_programs', UserProgram, {
      user_id: :get_migrated_user_ids,
      program_id: :get_program_ids_by_name
    })
  end

  def migration_groups
    [
      [
        ['person', Person, {
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          cause_of_death: :get_concept_ids
        }],
        ['relationship', Relationship, {
          creator: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          person_a: :get_person_ids,
          person_b: :get_person_ids,
          relationship: :get_relationship_type_ids
        }],
        ['person_name', PersonName, {
          person_id: :get_person_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['person_address', PersonAddress, {
          person_id: :get_person_ids,
          creator: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['person_attribute', PersonAttribute, {
          person_id: :get_person_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['patient', Patient, {
          patient_id: :get_person_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }]
      ],
      [
        ['patient_identifier', PatientIdentifier, {
          patient_id: :get_person_ids,
          creator: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['patient_program', PatientProgram, {
          patient_id: :get_person_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          program_id: :get_program_ids_by_name
        }],
        ['encounter', Encounter, {
          patient_id: :get_person_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          provider_id: :get_person_ids,
          encounter_type: :get_encounter_type_ids,
          program_id: :get_program_ids_by_name,
          form_id: :get_optional_form_ids
        }]
      ],
      [
        ['orders', Order, {
          encounter_id: :get_encounter_ids,
          patient_id: :get_person_ids,
          creator: :get_new_user_ids,
          orderer: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          order_type_id: :get_order_type_ids,
          concept_id: :get_concept_ids,
          discontinued_by: :get_new_user_ids,
          discontinued_reason: :get_concept_ids
        }],
        ['patient_state', PatientState, {
          patient_program_id: :get_patient_program_ids,
          state: :get_program_workflow_state_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }]
      ],
      [
        ['obs', Observation, {
          encounter_id: :get_encounter_ids,
          order_id: :get_optional_order_ids,
          creator: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          person_id: :get_person_ids,
          concept_id: :get_concept_ids,
          value_coded: :get_concept_ids,
          value_drug: :get_optional_drug_ids
        }],
        ['lims_acknowledgement_statuses', LimsAcknowledgementStatus, {
          order_id: :get_order_ids,
          test: :get_concept_ids,
          voided_by: :get_new_user_ids
        }]
      ],
      [
        ['drug_order', DrugOrder, {
          order_id: :get_order_ids,
          drug_inventory_id: :get_drug_ids
        }],
        ['pharmacies', Pharmacies, {}],
        ['pharmacy_batches', PharmacyBatch, {
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['pharmacy_batch_items', PharmacyBatchItem, {
          pharmacy_batch_id: :get_pharmacy_batch_ids,
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          drug_id: :get_drug_ids
        }],
        ['pharmacy_batch_item_reallocations', PharmacyBatchItemReallocation, {
          batch_item_id: :get_pharmacy_batch_item_ids,
          creator: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['pharmacy_batch_vvms', PharmacyBatchVvm, {
          batch_item_id: :get_pharmacy_batch_item_ids,
          voided_by: :get_new_user_ids
        }],
        ['pharmacy_stock_balances', PharmacyStockBalance, {
          drug_id: :get_drug_ids
        }],
        ['pharmacy_stock_verifications', PharmacyStockVerification, {
          creator: :get_new_user_ids,
          changed_by: :get_new_user_ids,
          voided_by: :get_new_user_ids
        }],
        ['pharmacy_obs', Pharmacy, {
          creator: :get_new_user_ids,
          voided_by: :get_new_user_ids,
          batch_item_id: :get_optional_pharmacy_batch_item_ids,
          stock_verification_id: :get_optional_pharmacy_stock_verification_ids,
          dispensation_obs_id: :get_obs_ids,
          obs_group_id: :get_obs_ids
        }]
      ]
    ]
  end

  def populate_records(source_table, target_model, dependencies = {}, reset_primary_key: true)
    unless migratable_table?(source_table, target_model)
      skip_table_message(source_table, 'source or target table does not exist')
      return { table: source_table, source_processed: 0, inserted: 0, duration: 0 }
    end

    table_started_at = Time.now
    total = count_source_rows(source_table)
    puts "\nMigrating #{source_table} -> #{target_model.table_name} (#{total} source rows)"
    source_processed = 0
    inserted = 0

    process_in_batches(source_table, target_model) do |records|
      source_batch_size = records.length
      records.each(&:symbolize_keys!)
      records = rewrite_location_ids(records, target_model)
      records = prepare_global_properties(records) if target_model.to_s == 'GlobalProperty'
      records = apply_dependency_mappings(records, dependencies)
      records = clear_deferred_foreign_keys(records, target_model)
      records = reject_existing_records(records, target_model)
      records = reject_invalid_records(records, target_model)
      records = reset_record_primary_keys(records, target_model) if reset_primary_key

      inserted += insert_records(target_model, records)
      source_processed += source_batch_size

      elapsed = Time.now - table_started_at
      rate = source_processed.positive? && elapsed.positive? ? (source_processed / elapsed).round(1) : 0
      percent = total.positive? ? ((source_processed.to_f / total) * 100).round(2) : 100
      not_inserted = source_processed - inserted

      puts "  #{source_table}: inserted #{inserted}, source processed #{source_processed}/#{total} " \
           "(#{percent}%), not inserted #{not_inserted}, elapsed #{format_duration(elapsed)}, #{rate} rows/s"
    end

    duration = Time.now - table_started_at
    puts "Completed #{source_table} in #{format_duration(duration)} " \
         "(source processed #{source_processed}, inserted #{inserted}, not inserted #{source_processed - inserted})"
    { table: source_table, source_processed: source_processed, inserted: inserted, duration: duration }
  end

  def process_in_batches(source_table, target_model)
    batch_column = numeric_batch_column(source_table)
    if batch_column
      min_max = ActiveRecord::Base.connection.select_one(<<~SQL)
        SELECT MIN(#{q(batch_column)}) AS min_id, MAX(#{q(batch_column)}) AS max_id
        FROM #{table_ref(SOURCE_DB, source_table)}
      SQL
      min_id = min_max['min_id'].to_i
      max_id = min_max['max_id'].to_i

      current_min = min_id
      while current_min <= max_id
        current_max = current_min + BATCH_SIZE - 1
        records = select_source_rows(
          source_table,
          "#{q(batch_column)} BETWEEN #{current_min} AND #{current_max}",
          nil,
          nil,
          target_model
        )
        yield(records) if records.any?
        current_min = current_max + 1
      end
    else
      offset = 0
      loop do
        records = select_source_rows(source_table, nil, BATCH_SIZE, offset, target_model)
        break if records.empty?

        yield(records)
        offset += BATCH_SIZE
      end
    end
  end

  def apply_dependency_mappings(records, dependencies)
    dependencies.each do |key, mapping_method|
      next if records.empty?
      next unless records.first.key?(key)

      records = send(mapping_method, records, key)
    end
    records
  end

  def rewrite_location_ids(records, target_model)
    return records if PRESERVE_LOCATION_IDS
    return records unless LOCATION_TABLE_MODELS.include?(target_model.to_s)
    return records if records.empty? || !records.first.key?(:location_id)

    source_location_codes = records.each_with_object({}) do |record, codes|
      codes[record.object_id] = source_location_code_for_record(record)
    end
    source_location_values = source_location_codes.values.compact.uniq
    ensure_location_id_cache(source_location_values)

    records.each do |record|
      source_location_value = normalize_location_code(record[:location_id])
      source_code = source_location_codes[record.object_id]
      next if source_location_value.blank? && source_code.blank?

      if source_code.blank?
        record[:location_id] = nil if numeric_location_value?(source_location_value)
        UNMAPPED_LOCATION_CODES[source_location_value] += 1
        next
      end

      mapped_location_id = LOCATION_ID_CACHE[source_code]
      if mapped_location_id
        record[:location_id] = mapped_location_id
      elsif numeric_location_value?(source_location_value)
        record[:location_id] = nil
        UNMAPPED_LOCATION_CODES[source_code] += 1
      elsif target_location_id
        record[:location_id] = target_location_id
      else
        UNMAPPED_LOCATION_CODES[source_code] += 1
      end
    end
    records
  end

  def prepare_global_properties(records)
    return records if records.empty?
    return records unless column_names(TARGET_DB, 'global_property').include?('location_id')

    source_location_values = records.filter_map { |record| normalize_location_code(record[:location_id]) }
    source_location_values.concat(
      records.filter_map do |record|
        normalize_location_code(record[:property_value]) if record[:property].to_s == 'current_health_center_id'
      end
    )
    source_location_values.uniq!

    numeric_source_location_ids = source_location_values.select { |value| numeric_location_value?(value) }
    source_location_id_map = target_location_ids_by_source_location_id(numeric_source_location_ids)
    fixed_source_codes = numeric_source_location_ids.filter_map { |value| FIXED_SOURCE_LOCATION_CODE_MAPPINGS[value] }
    facility_codes = source_location_values.reject { |value| numeric_location_value?(value) }
    ensure_location_id_cache((facility_codes + fixed_source_codes).uniq)
    fallback_location_id = target_location_id || records.filter_map do |record|
      next unless record[:property].to_s == 'current_health_center_id'

      mapped_global_property_location_id(record[:property_value], source_location_id_map)
    end.first

    records.each do |record|
      record[:location_id] = mapped_global_property_location_id(record[:location_id], source_location_id_map)
      record[:location_id] = fallback_location_id.to_s if record[:location_id].blank? && fallback_location_id

      next unless record[:property].to_s == 'current_health_center_id'
      next if record[:property_value].blank?

      mapped_property_value = mapped_global_property_location_id(record[:property_value], source_location_id_map)
      record[:property_value] = mapped_property_value if mapped_property_value.present?
    end

    records
  end

  def mapped_global_property_location_id(value, source_location_id_map)
    source_value = normalize_location_code(value)
    return nil if source_value.blank?
    return source_value if PRESERVE_LOCATION_IDS

    mapped_location_id = if numeric_location_value?(source_value)
                           fixed_source_code = FIXED_SOURCE_LOCATION_CODE_MAPPINGS[source_value]
                           source_location_id_map[source_value] || LOCATION_ID_CACHE[fixed_source_code]
                         else
                           LOCATION_ID_CACHE[source_value]
                         end

    mapped_location_id ||= target_location_id
    UNMAPPED_LOCATION_CODES[source_value] += 1 if mapped_location_id.blank?
    mapped_location_id&.to_s
  end

  def ensure_location_id_cache(source_location_values)
    missing_codes = source_location_values.reject { |code| LOCATION_ID_CACHE.key?(code) }
    return if missing_codes.empty?

    target_location_ids_by_code(missing_codes).each do |source_code, target_location_id|
      LOCATION_ID_CACHE[source_code] = target_location_id
    end

    missing_codes.each do |code|
      LOCATION_ID_CACHE[code] = nil unless LOCATION_ID_CACHE.key?(code)
    end
  end

  def source_location_code_for_record(record)
    source_location_value = normalize_location_code(record[:location_id])
    return source_user_location_code(record[:creator]) if source_location_value.blank?
    return source_location_value unless numeric_location_value?(source_location_value)
    return FIXED_SOURCE_LOCATION_CODE_MAPPINGS[source_location_value] if FIXED_SOURCE_LOCATION_CODE_MAPPINGS.key?(source_location_value)

    source_user_location_code(record[:creator])
  end

  def source_user_location_code(source_user_id)
    return nil if source_user_id.blank?
    source_user_id = source_user_id.to_i
    return SOURCE_USER_LOCATION_CODE_CACHE[source_user_id] if SOURCE_USER_LOCATION_CODE_CACHE.key?(source_user_id)

    user_location_value = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT location_id
      FROM #{table_ref(SOURCE_DB, 'users')}
      WHERE user_id = #{source_user_id}
      LIMIT 1
    SQL

    location_code = normalize_location_code(user_location_value)
    location_code = FIXED_SOURCE_LOCATION_CODE_MAPPINGS[location_code] if location_code && FIXED_SOURCE_LOCATION_CODE_MAPPINGS.key?(location_code)
    location_code = nil if location_code && numeric_location_value?(location_code)
    SOURCE_USER_LOCATION_CODE_CACHE[source_user_id] = location_code
  end

  def numeric_location_value?(value)
    value.to_s.match?(/\A\d+\z/)
  end

  def target_location_ids_by_code(source_codes)
    return {} if source_codes.empty?

    attribute_type_id = facility_code_attribute_type_id
    attribute_type_filter = attribute_type_id ? "AND la.attribute_type_id = #{attribute_type_id}" : ''
    quoted_codes = source_codes.map { |code| quote(code) }.join(',')

    ActiveRecord::Base.connection.select_all(<<~SQL).to_a.each_with_object({}) do |row, map|
      SELECT TRIM(la.value_reference) AS source_code, la.location_id
      FROM #{table_ref(TARGET_DB, 'location_attribute')} la
      INNER JOIN #{table_ref(TARGET_DB, 'location')} l
        ON l.location_id = la.location_id
       AND COALESCE(l.retired, 0) = 0
      WHERE la.voided = 0
        #{attribute_type_filter}
        AND TRIM(la.value_reference) IN (#{quoted_codes})
      ORDER BY la.location_id
    SQL
      map[normalize_location_code(row['source_code'])] ||= row['location_id'].to_i
    end
  end

  def target_location_ids_by_source_location_id(source_location_ids)
    return {} if source_location_ids.empty?
    return {} unless table_exists?(SOURCE_DB, 'location') && table_exists?(TARGET_DB, 'location')

    source_rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
      SELECT location_id, uuid
      FROM #{table_ref(SOURCE_DB, 'location')}
      WHERE location_id IN (#{source_location_ids.map(&:to_i).join(',')})
    SQL

    uuid_by_source_id = source_rows.each_with_object({}) do |row, map|
      map[normalize_location_code(row['location_id'])] = row['uuid']
    end
    return {} if uuid_by_source_id.empty?

    quoted_uuids = uuid_by_source_id.values.compact.map { |uuid| quote(uuid) }.join(',')
    return {} if quoted_uuids.blank?

    target_id_by_uuid = ActiveRecord::Base.connection.select_all(<<~SQL).to_a.each_with_object({}) do |row, map|
      SELECT uuid, location_id
      FROM #{table_ref(TARGET_DB, 'location')}
      WHERE COALESCE(retired, 0) = 0
        AND uuid IN (#{quoted_uuids})
    SQL
      map[row['uuid']] = row['location_id'].to_i
    end

    uuid_by_source_id.each_with_object({}) do |(source_location_id, uuid), map|
      target_location_id = target_id_by_uuid[uuid]
      map[source_location_id] = target_location_id if target_location_id
    end
  end

  def facility_code_attribute_type_id
    return @facility_code_attribute_type_id if defined?(@facility_code_attribute_type_id)
    return @facility_code_attribute_type_id = nil unless table_exists?(TARGET_DB, 'location_attribute_type')

    @facility_code_attribute_type_id = ActiveRecord::Base.connection.select_value(<<~SQL)&.to_i
      SELECT location_attribute_type_id
      FROM #{table_ref(TARGET_DB, 'location_attribute_type')}
      WHERE name = #{quote(LOCATION_ATTRIBUTE_TYPE_NAME)}
      LIMIT 1
    SQL
  end

  def normalize_location_code(value)
    value.to_s.strip.presence
  end

  def normalized_record_location_id(record)
    normalize_location_code(record[:location_id])
  end

  def clear_deferred_foreign_keys(records, target_model)
    case target_model.to_s
    when 'Observation'
      records.each do |record|
        record[:obs_group_id] = nil if record.key?(:obs_group_id)
        record[:value_coded_name_id] = nil if record.key?(:value_coded_name_id)
      end
    when 'Order'
      records.each { |record| record[:obs_id] = nil if record.key?(:obs_id) }
    end
    records
  end

  def reject_existing_records(records, target_model)
    return records if records.empty?

    case target_model.to_s
    when 'Patient'
      existing_ids = target_model.unscoped.where(patient_id: records.map { |record| record[:patient_id] }.compact).pluck(:patient_id).to_set
      records.reject { |record| existing_ids.include?(record[:patient_id]) }
    when 'DrugOrder', 'LimsAcknowledgementStatus'
      existing_ids = target_model.unscoped.where(order_id: records.map { |record| record[:order_id] }.compact).pluck(:order_id).to_set
      records.reject { |record| existing_ids.include?(record[:order_id]) }
    when 'UserRole'
      keys = target_model.unscoped.where(user_id: records.map { |record| record[:user_id] }.compact)
                         .pluck(:role, :user_id).to_set
      records.reject { |record| keys.include?([record[:role], record[:user_id]]) }
    when 'UserProperty'
      keys = target_model.unscoped.where(user_id: records.map { |record| record[:user_id] }.compact)
                         .pluck(:user_id, :property).to_set
      records.reject { |record| keys.include?([record[:user_id], record[:property]]) }
    when 'UserProgram'
      keys = target_model.unscoped.where(user_id: records.map { |record| record[:user_id] }.compact)
                         .pluck(:user_id, :program_id).to_set
      records.reject { |record| keys.include?([record[:user_id], record[:program_id]]) }
    when 'GlobalProperty'
      properties = records.map { |record| record[:property] }.compact
      if column_names(TARGET_DB, target_model.table_name).include?('location_id')
        locations = records.map { |record| normalized_record_location_id(record) }.uniq
        keys = target_model.unscoped.where(property: properties, location_id: locations)
                           .pluck(:property, :location_id)
                           .map { |property, location_id| [property, normalize_location_code(location_id)] }
                           .to_set
        records.reject { |record| keys.include?([record[:property], normalized_record_location_id(record)]) }
      else
        existing_properties = target_model.unscoped.where(property: properties).pluck(:property).to_set
        records.reject { |record| existing_properties.include?(record[:property]) }
      end
    else
      if records.first.key?(:uuid)
        existing_uuids = target_model.unscoped.where(uuid: records.map { |record| record[:uuid] }.compact).pluck(:uuid).to_set
        records.reject { |record| existing_uuids.include?(record[:uuid]) }
      elsif (primary_key = simple_primary_key(target_model)) && records.first.key?(primary_key.to_sym)
        existing_ids = target_model.unscoped.where(primary_key => records.map { |record| record[primary_key.to_sym] }.compact)
                                   .pluck(primary_key).to_set
        records.reject { |record| existing_ids.include?(record[primary_key.to_sym]) }
      else
        records
      end
    end
  end

  def reject_invalid_records(records, target_model)
    required_keys = case target_model.to_s
                    when 'Observation'
                      %i[concept_id person_id]
                    when 'Order'
                      %i[concept_id patient_id order_type_id]
                    when 'Encounter'
                      %i[patient_id encounter_type]
                    when 'PatientProgram'
                      %i[patient_id program_id]
                    when 'PatientState'
                      %i[patient_program_id state]
                    when 'DrugOrder'
                      %i[order_id]
                    when 'LimsAcknowledgementStatus'
                      %i[order_id test]
                    when 'UserRole'
                      %i[user_id role]
                    when 'UserProgram'
                      %i[user_id program_id]
                    when 'GlobalProperty'
                      %i[property]
                    else
                      []
                    end

    return records if required_keys.empty?

    table_name = target_model.table_name
    records.reject do |record|
      missing = required_keys.select { |key| record[key].blank? }
      if missing.any?
        track_skipped(table_name, record, "missing #{missing.join(', ')}")
        true
      else
        false
      end
    end
  end

  def reset_record_primary_keys(records, target_model)
    return records if records.empty?
    return records if NON_RESET_MODELS.include?(target_model.to_s)

    primary_key = target_model.primary_key
    records.each do |record|
      if primary_key.is_a?(Array)
        primary_key.each { |key| record[key.to_sym] = nil }
      elsif primary_key.present?
        record[primary_key.to_sym] = nil
      end
      record[:id] = nil if record.key?(:id)
    end
    records
  end

  def insert_records(target_model, records)
    records = records.compact
    return 0 if records.empty?

    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 0')
    target_model.unscoped.insert_all!(records)
    records.length
  rescue ActiveRecord::RecordNotUnique, Mysql2::Error => e
    puts "  Skipped batch for #{target_model.table_name}: #{e.message.lines.first.strip}"
    records.each { |record| track_skipped(target_model.table_name, record, e.message.lines.first.strip) }
    0
  ensure
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 1') if ActiveRecord::Base.connected?
  end

  def create_or_find_person(source_person_id)
    return nil if source_person_id.blank?

    source_person = select_source_rows('person', "person_id = #{source_person_id.to_i}", nil, nil, Person).first
    return nil unless source_person

    existing = Person.unscoped.find_by(uuid: source_person['uuid'])
    return existing.person_id if existing

    source_person.symbolize_keys!
    source_person[:person_id] = nil
    %i[creator changed_by voided_by cause_of_death].each do |key|
      next unless source_person.key?(key)

      case key
      when :cause_of_death
        source_person[key] = concept_id_map[source_person[key].to_i] if source_person[key].present?
      else
        source_person[key] = new_user_id(source_person[key])
      end
    end

    insert_records(Person, [source_person])
    Person.unscoped.find_by(uuid: source_person[:uuid])&.person_id
  end

  def create_users_persons(records, key)
    records.each do |record|
      record[key] = create_or_find_person(record[key])
      track_skipped('users', record, 'person_id could not be mapped') if record[key].blank?
    end
    records.reject { |record| record[key].blank? }
  end

  def get_new_user_ids(records, key)
    records.each do |record|
      next if record[key].blank?

      record[key] = new_user_id(record[key])
      track_skipped('users', record, "#{key} could not be mapped") if record[key].blank?
    end
    records
  end

  def get_migrated_user_ids(records, key)
    source_ids = records.map { |record| record[key].to_i if record[key].present? }.compact.uniq
    return records if source_ids.empty?

    missing_ids = source_ids.reject { |source_id| MIGRATED_USER_ID_CACHE.key?(source_id) }
    if missing_ids.any?
      source_rows = select_source_rows('users', "#{q('user_id')} IN (#{missing_ids.join(',')})", nil, nil, User)
      source_uuid_by_id = source_rows.index_by { |row| row['user_id'].to_i }.transform_values { |row| row['uuid'] }
      target_ids_by_uuid = User.unscoped.where(uuid: source_uuid_by_id.values.compact).pluck(:uuid, :user_id).to_h

      missing_ids.each do |source_id|
        MIGRATED_USER_ID_CACHE[source_id] = target_ids_by_uuid[source_uuid_by_id[source_id]]
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      source_id = record[key].to_i
      record[key] = MIGRATED_USER_ID_CACHE[source_id]
      if record[key].blank?
        track_skipped('user_mapping', record, "#{key}=#{source_id} could not be mapped to a migrated user")
        true
      else
        false
      end
    end
  end

  def new_user_id(source_user_id)
    return nil if source_user_id.blank?
    return USER_ID_CACHE[source_user_id] if USER_ID_CACHE.key?(source_user_id)

    source_user = select_source_rows('users', "user_id = #{source_user_id.to_i}", nil, nil, User).first
    target_user_id = if source_user
                       User.unscoped.find_by(uuid: source_user['uuid'])&.user_id
                     end
    target_user_id ||= User.unscoped.minimum(:user_id) || 1
    USER_ID_CACHE[source_user_id] = target_user_id
  end

  def get_person_ids(records, key)
    fetch_new_ids(records, key, 'person', 'person_id', Person, PERSON_ID_CACHE)
  end

  def get_encounter_ids(records, key)
    fetch_new_ids(records, key, 'encounter', 'encounter_id', Encounter, ENCOUNTER_ID_CACHE)
  end

  def get_order_ids(records, key)
    fetch_new_ids(records, key, 'orders', 'order_id', Order, ORDER_ID_CACHE)
  end

  def get_optional_order_ids(records, key)
    fetch_new_ids(records, key, 'orders', 'order_id', Order, ORDER_ID_CACHE, optional: true)
  end

  def get_obs_ids(records, key)
    fetch_new_ids(records, key, 'obs', 'obs_id', Observation, OBS_ID_CACHE)
  end

  def get_patient_program_ids(records, key)
    fetch_new_ids(records, key, 'patient_program', 'patient_program_id', PatientProgram, PATIENT_PROGRAM_ID_CACHE)
  end

  def get_program_workflow_state_ids(records, key)
    source_ids = records.map { |record| record[key] }.compact.uniq
    return records if source_ids.empty?

    cache = NAME_ID_CACHE[:program_workflow_state]
    missing_ids = source_ids.reject { |source_id| cache.key?(source_id) }

    if missing_ids.any?
      source_rows = ActiveRecord::Base.connection.select_all(<<~SQL).to_a
        SELECT program_workflow_state_id, concept_id, uuid
        FROM #{table_ref(SOURCE_DB, 'program_workflow_state')}
        WHERE program_workflow_state_id IN (#{missing_ids.map(&:to_i).join(',')})
      SQL

      uuid_by_source_id = source_rows.index_by { |row| row['program_workflow_state_id'].to_i }
                                   .transform_values { |row| row['uuid'] }
      target_id_by_uuid = ProgramWorkflowState.unscoped.where(uuid: uuid_by_source_id.values.compact)
                                              .pluck(:uuid, :program_workflow_state_id)
                                              .to_h

      mapped_concept_ids = source_rows.filter_map { |row| concept_id_map[row['concept_id'].to_i] }.uniq
      target_state_by_concept = mapped_concept_ids.empty? ? {} : ProgramWorkflowState.unscoped
                                                                           .where(concept_id: mapped_concept_ids)
                                                                           .pluck(:concept_id, :program_workflow_state_id)
                                                                           .to_h

      source_rows.each do |row|
        source_id = row['program_workflow_state_id'].to_i
        cache[source_id] = target_id_by_uuid[row['uuid']] || target_state_by_concept[concept_id_map[row['concept_id'].to_i]]
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      record[key] = cache[record[key]]
      if record[key].blank?
        track_skipped('patient_state', record, "#{key} could not be mapped")
        true
      else
        false
      end
    end
  end

  def get_report_design_ids(records, key)
    fetch_new_ids(records, key, 'reporting_report_design', 'id', Report, REPORT_DESIGN_ID_CACHE)
  end

  def get_stock_verification_ids(records, key)
    fetch_new_ids(records, key, 'pharmacy_stock_verifications', 'id', PharmacyStockVerification, STOCK_VERIFICATION_ID_CACHE)
  end

  def get_pharmacy_batch_ids(records, key)
    fetch_preserved_primary_ids(records, key, PharmacyBatch)
  end

  def get_pharmacy_batch_item_ids(records, key)
    fetch_preserved_primary_ids(records, key, PharmacyBatchItem)
  end

  def get_optional_pharmacy_batch_item_ids(records, key)
    fetch_preserved_primary_ids(records, key, PharmacyBatchItem, optional: true)
  end

  def get_optional_pharmacy_stock_verification_ids(records, key)
    fetch_preserved_primary_ids(records, key, PharmacyStockVerification, optional: true)
  end

  def fetch_preserved_primary_ids(records, key, target_model, optional: false)
    source_ids = records.map { |record| record[key] }.compact.uniq
    return records if source_ids.empty?

    primary_key = simple_primary_key(target_model)
    return records unless primary_key

    cache_key = [:preserved_primary_id, target_model.table_name, primary_key]
    missing_ids = source_ids.reject { |source_id| NAME_ID_CACHE[cache_key].key?(source_id) }

    if missing_ids.any?
      existing_ids = target_model.unscoped.where(primary_key => missing_ids).pluck(primary_key).to_set
      missing_ids.each do |source_id|
        NAME_ID_CACHE[cache_key][source_id] = existing_ids.include?(source_id) ? source_id : nil
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      source_id = record[key]
      record[key] = NAME_ID_CACHE[cache_key][source_id]
      if record[key].blank?
        if optional
          record[key] = nil
          false
        else
          track_skipped(target_model.table_name, record, "#{key}=#{source_id} could not be mapped")
          true
        end
      else
        false
      end
    end
  end

  def fetch_new_ids(records, key, source_table, id_column, target_model, cache, optional: false)
    source_ids = records.map { |record| record[key] }.compact.uniq
    return records if source_ids.empty?

    source_ids_to_load = source_ids.reject { |source_id| cache.key?(source_id) }
    if source_ids_to_load.any?
      source_rows = select_source_rows(source_table, "#{q(id_column)} IN (#{source_ids_to_load.map(&:to_i).join(',')})", nil, nil, target_model)
      source_uuid_by_id = source_rows.index_by { |row| row[id_column].to_i }.transform_values { |row| row['uuid'] }
      target_ids_by_uuid = target_model.unscoped.where(uuid: source_uuid_by_id.values.compact).pluck(:uuid, id_column).to_h

      source_ids_to_load.each do |source_id|
        cache[source_id] = target_ids_by_uuid[source_uuid_by_id[source_id.to_i]]
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      source_id = record[key]
      record[key] = cache[source_id]
      if record[key].blank?
        if optional
          record[key] = nil
          false
        else
          track_skipped(target_model.table_name, record, "#{key}=#{source_id} could not be mapped")
          true
        end
      else
        false
      end
    end
  end

  def get_concept_ids(records, key)
    records.reject do |record|
      next false if record[key].blank?

      mapped_id = concept_id_map[record[key].to_i]
      if mapped_id
        record[key] = mapped_id
        false
      elsif OPTIONAL_CONCEPT_FIELDS.include?(key)
        record[key] = nil
        false
      else
        track_skipped('concept_mapping', record, "#{key}=#{record[key]} could not be mapped")
        true
      end
    end
  end

  def get_relationship_type_ids(records, key)
    source_ids = records.map { |record| record[key] }.compact.uniq
    return records if source_ids.empty?

    cache_key = [:relationship_type, 'relationship_type_id']
    source_name_cache_key = [:source_name, cache_key]
    missing_ids = source_ids.reject { |source_id| NAME_ID_CACHE[cache_key].key?(source_id) }

    if missing_ids.any?
      rows = select_source_rows(
        'relationship_type',
        "#{q('relationship_type_id')} IN (#{missing_ids.map(&:to_i).join(',')})",
        nil,
        nil,
        RelationshipType
      )
      source_name_by_id = rows.index_by { |row| row['relationship_type_id'].to_i }
                              .transform_values { |row| row['a_is_to_b'].to_s.strip.presence }
      normalized_source_name_by_id = source_name_by_id.transform_values { |name| normalize_name(name) }
      target_id_by_name = target_ids_by_name(
        RelationshipType,
        'relationship_type_id',
        'a_is_to_b',
        normalized_source_name_by_id.values.compact.uniq
      )
      target_ids = RelationshipType.unscoped.where(relationship_type_id: missing_ids).pluck(:relationship_type_id).to_set

      missing_ids.each do |source_id|
        NAME_ID_CACHE[cache_key][source_id] = target_id_by_name[normalized_source_name_by_id[source_id.to_i]]
        NAME_ID_CACHE[cache_key][source_id] ||= source_id if target_ids.include?(source_id)
        NAME_ID_CACHE[source_name_cache_key][source_id] = source_name_by_id[source_id.to_i]
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      source_id = record[key]
      record[key] = NAME_ID_CACHE[cache_key][source_id]
      if record[key].blank?
        source_name = NAME_ID_CACHE[source_name_cache_key][source_id]
        source_description = source_name.present? ? "#{key}=#{source_id} (#{source_name})" : "#{key}=#{source_id}"
        track_skipped('relationship_type', record, "#{source_description} could not be mapped by name or target id")
        true
      else
        false
      end
    end
  end

  def get_encounter_type_ids(records, key)
    fetch_new_ids_by_name(records, key, 'encounter_type', 'encounter_type_id', 'name', EncounterType)
  end

  def get_order_type_ids(records, key)
    fetch_new_ids_by_name(records, key, 'order_type', 'order_type_id', 'name', OrderType)
  end

  def get_form_ids(records, key)
    fetch_new_ids_by_name(records, key, 'form', 'form_id', 'name', Form)
  end

  def get_optional_form_ids(records, key)
    fetch_new_ids_by_name(records, key, 'form', 'form_id', 'name', Form, optional: true)
  end

  def get_program_ids_by_name(records, key)
    fetch_new_ids_by_name(records, key, 'program', 'program_id', 'name', Program)
  end

  def get_drug_ids(records, key)
    fetch_drug_ids(records, key)
  end

  def get_optional_drug_ids(records, key)
    fetch_drug_ids(records, key, optional: true)
  end

  def fetch_drug_ids(records, key, optional: false)
    source_ids = records.map { |record| record[key] }.compact.uniq
    return records if source_ids.empty?
    return records unless table_exists?(SOURCE_DB, 'drug') && table_exists?(TARGET_DB, Drug.table_name)

    cache_key = [:drug, 'drug_id']
    source_name_cache_key = [:source_name, cache_key]
    missing_ids = source_ids.reject { |source_id| NAME_ID_CACHE[cache_key].key?(source_id) }

    if missing_ids.any?
      rows = select_source_rows('drug', "#{q('drug_id')} IN (#{missing_ids.map(&:to_i).join(',')})", nil, nil, Drug)
      source_row_by_id = rows.index_by { |row| row['drug_id'].to_i }
      source_uuid_by_id = source_row_by_id.transform_values { |row| row['uuid'].to_s.strip.presence }
      source_name_by_id = source_row_by_id.transform_values { |row| row['name'].to_s.strip.presence }

      target_ids_by_uuid = target_drug_ids_by_uuid(source_uuid_by_id.values.compact.uniq)
      target_id_by_name = target_ids_by_name(
        Drug,
        'drug_id',
        'name',
        source_name_by_id.values.compact.map { |name| normalize_name(name) }.uniq
      )

      missing_ids.each do |source_id|
        source_id = source_id.to_i
        NAME_ID_CACHE[cache_key][source_id] = target_ids_by_uuid[source_uuid_by_id[source_id]]
        NAME_ID_CACHE[cache_key][source_id] ||= target_id_by_name[normalize_name(source_name_by_id[source_id])]
        NAME_ID_CACHE[source_name_cache_key][source_id] = source_name_by_id[source_id]
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      source_id = record[key].to_i
      record[key] = NAME_ID_CACHE[cache_key][source_id]
      if record[key].blank?
        if optional
          record[key] = nil
          false
        else
          source_name = NAME_ID_CACHE[source_name_cache_key][source_id]
          source_description = source_name.present? ? "#{key}=#{source_id} (#{source_name})" : "#{key}=#{source_id}"
          track_skipped(Drug.table_name, record, "#{source_description} could not be mapped by uuid or name")
          true
        end
      else
        false
      end
    end
  end

  def target_drug_ids_by_uuid(source_uuids)
    return {} if source_uuids.empty?
    return {} unless column_names(TARGET_DB, Drug.table_name).include?('uuid')

    Drug.unscoped.where(uuid: source_uuids).pluck(:uuid, :drug_id).to_h
  end

  def fetch_new_ids_by_name(records, key, source_table, id_column, name_column, target_model, optional: false)
    source_ids = records.map { |record| record[key] }.compact.uniq
    return records if source_ids.empty?
    return records unless table_exists?(SOURCE_DB, source_table) && table_exists?(TARGET_DB, target_model.table_name)

    cache_key = [source_table, id_column, name_column, target_model.table_name]
    source_name_cache_key = [:source_name, cache_key]
    missing_ids = source_ids.reject { |source_id| NAME_ID_CACHE[cache_key].key?(source_id) }

    if missing_ids.any?
      rows = select_source_rows(source_table, "#{q(id_column)} IN (#{missing_ids.map(&:to_i).join(',')})", nil, nil, target_model)
      source_name_by_id = rows.index_by { |row| row[id_column].to_i }.transform_values { |row| row[name_column].to_s.strip.presence }
      normalized_source_name_by_id = source_name_by_id.transform_values { |name| normalize_name(name) }
      target_names = normalized_source_name_by_id.values.compact.uniq
      target_id_by_name = target_ids_by_name(target_model, id_column, name_column, target_names)

      missing_ids.each do |source_id|
        NAME_ID_CACHE[cache_key][source_id] = target_id_by_name[normalized_source_name_by_id[source_id.to_i]]
        NAME_ID_CACHE[source_name_cache_key][source_id] = source_name_by_id[source_id.to_i]
      end
    end

    records.reject do |record|
      next false if record[key].blank?

      source_id = record[key]
      record[key] = NAME_ID_CACHE[cache_key][source_id]
      if record[key].blank?
        if optional
          record[key] = nil
          false
        else
          source_name = NAME_ID_CACHE[source_name_cache_key][source_id]
          source_description = source_name.present? ? "#{key}=#{source_id} (#{source_name})" : "#{key}=#{source_id}"
          track_skipped(target_model.table_name, record, "#{source_description} could not be mapped by name")
          true
        end
      else
        false
      end
    end
  end

  def target_ids_by_name(target_model, id_column, name_column, normalized_names)
    return {} if normalized_names.empty?

    quoted_names = normalized_names.map { |name| quote(name) }.join(',')
    target_model.unscoped
                .where("LOWER(TRIM(#{q(name_column)})) IN (#{quoted_names})")
                .pluck(name_column, id_column)
                .each_with_object({}) do |(name, id), hash|
      hash[normalize_name(name)] ||= id
    end
  end

  def backfill_orders_obs_ids
    return unless table_exists?(SOURCE_DB, 'orders') && table_exists?(SOURCE_DB, 'obs')

    started_at = Time.now
    puts "\nBackfilling orders.obs_id..."
    align_uuid_collations(%w[orders obs])
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 0')
    ActiveRecord::Base.connection.execute(<<~SQL)
      UPDATE #{q(TARGET_DB)}.#{q('orders')} target_order
      INNER JOIN #{table_ref(SOURCE_DB, 'orders')} source_order
        ON target_order.uuid = source_order.uuid
      INNER JOIN #{table_ref(SOURCE_DB, 'obs')} source_obs
        ON source_obs.obs_id = source_order.obs_id
      INNER JOIN #{q(TARGET_DB)}.#{q('obs')} target_obs
        ON target_obs.uuid = source_obs.uuid
      SET target_order.obs_id = target_obs.obs_id
      WHERE source_order.obs_id IS NOT NULL
        AND target_order.obs_id IS NULL
    SQL
    puts "  orders.obs_id backfill completed in #{format_duration(Time.now - started_at)}"
  rescue StandardError => e
    puts "  Could not backfill orders.obs_id after #{format_duration(Time.now - started_at)}: #{e.message.lines.first.strip}"
  ensure
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 1') if ActiveRecord::Base.connected?
  end

  def update_group_obs_ids
    return unless table_exists?(SOURCE_DB, 'obs')

    started_at = Time.now
    puts 'Updating obs.obs_group_id...'
    align_uuid_collations(%w[obs])
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 0')
    ActiveRecord::Base.connection.execute(<<~SQL)
      UPDATE #{q(TARGET_DB)}.#{q('obs')} target_obs
      INNER JOIN #{table_ref(SOURCE_DB, 'obs')} source_obs
        ON target_obs.uuid = source_obs.uuid
      INNER JOIN #{table_ref(SOURCE_DB, 'obs')} source_parent
        ON source_parent.obs_id = source_obs.obs_group_id
      INNER JOIN #{q(TARGET_DB)}.#{q('obs')} target_parent
        ON target_parent.uuid = source_parent.uuid
      SET target_obs.obs_group_id = target_parent.obs_id
      WHERE source_obs.obs_group_id IS NOT NULL
        AND target_obs.obs_group_id IS NULL
    SQL
    puts "  obs.obs_group_id update completed in #{format_duration(Time.now - started_at)}"
  rescue StandardError => e
    puts "  Could not update obs.obs_group_id after #{format_duration(Time.now - started_at)}: #{e.message.lines.first.strip}"
  ensure
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 1') if ActiveRecord::Base.connected?
  end

  def align_uuid_collations(table_names)
    table_names.each do |table_name|
      source_column = uuid_column_metadata(SOURCE_DB, table_name)
      target_column = uuid_column_metadata(TARGET_DB, table_name)
      next unless source_column && target_column
      next if source_column['COLLATION_NAME'] == target_column['COLLATION_NAME'] &&
              source_column['CHARACTER_SET_NAME'] == target_column['CHARACTER_SET_NAME']

      nullable = target_column['IS_NULLABLE'] == 'NO' ? 'NOT NULL' : 'NULL'
      puts "  Aligning #{TARGET_DB}.#{table_name}.uuid collation " \
           "#{target_column['COLLATION_NAME']} -> #{source_column['COLLATION_NAME']}..."

      ActiveRecord::Base.connection.execute(<<~SQL)
        ALTER TABLE #{q(TARGET_DB)}.#{q(table_name)}
        MODIFY #{q('uuid')} #{target_column['COLUMN_TYPE']}
        CHARACTER SET #{source_column['CHARACTER_SET_NAME']}
        COLLATE #{source_column['COLLATION_NAME']}
        #{nullable}
      SQL
    rescue StandardError => e
      puts "  Could not align #{TARGET_DB}.#{table_name}.uuid collation: #{e.message.lines.first.strip}"
    end
  end

  def uuid_column_metadata(database, table_name)
    ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT COLUMN_TYPE, CHARACTER_SET_NAME, COLLATION_NAME, IS_NULLABLE
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = #{quote(database)}
        AND TABLE_NAME = #{quote(table_name)}
        AND COLUMN_NAME = 'uuid'
      LIMIT 1
    SQL
  end

  def write_skipped_records_report
    if UNMAPPED_LOCATION_CODES.any?
      SKIPPED_RECORDS['unmapped_location_codes'] = UNMAPPED_LOCATION_CODES.sort.to_h.map do |source_code, count|
        {
          source_location_value: source_code,
          count: count,
          reason: "No #{TARGET_DB}.location_attribute value_reference match"
        }
      end
    end

    return if SKIPPED_RECORDS.empty?

    print_skipped_records_summary
    File.write(SKIPPED_RECORDS_FILE, JSON.pretty_generate(SKIPPED_RECORDS))
    puts "Skipped-record report written to #{SKIPPED_RECORDS_FILE}."
  end

  def print_skipped_records_summary
    puts 'Skipped-record summary:'
    SKIPPED_RECORDS.each do |table_name, rows|
      puts "  #{table_name}: #{rows.length}"
      rows.group_by { |row| row[:reason] || row['reason'] }
          .sort_by { |_, grouped_rows| -grouped_rows.length }
          .first(5)
          .each { |reason, grouped_rows| puts "    #{grouped_rows.length} #{reason}" }
    end
  end

  def track_skipped(table_name, record, reason)
    id = record[:uuid] || record[:id] || record[:order_id] || record[:obs_id] || record[:person_id] || record[:patient_id]
    SKIPPED_RECORDS[table_name.to_s] << {
      id: id,
      reason: reason
    }
  end

  def count_source_rows(source_table)
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table_ref(SOURCE_DB, source_table)}").to_i
  end

  def select_source_rows(source_table, where_clause = nil, limit = nil, offset = nil, target_model = nil)
    columns = selectable_columns(source_table, target_model)
    sql = +"SELECT #{columns.map { |column| q(column) }.join(', ')} FROM #{table_ref(SOURCE_DB, source_table)}"
    sql << " WHERE #{where_clause}" if where_clause.present?
    sql << " LIMIT #{limit.to_i}" if limit
    sql << " OFFSET #{offset.to_i}" if offset
    ActiveRecord::Base.connection.select_all(sql).to_a
  end

  def selectable_columns(source_table, target_model)
    source_columns = column_names(SOURCE_DB, source_table)
    return source_columns unless target_model

    target_columns = column_names(TARGET_DB, target_model.table_name)
    common_columns = source_columns & target_columns
    common_columns.empty? ? source_columns : common_columns
  end

  def numeric_batch_column(source_table)
    primary_key = primary_key_column(SOURCE_DB, source_table)
    return primary_key if primary_key && numeric_column?(SOURCE_DB, source_table, primary_key)

    column_names(SOURCE_DB, source_table).find { |column| numeric_column?(SOURCE_DB, source_table, column) }
  end

  def primary_key_column(database, table_name)
    ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT COLUMN_NAME
      FROM information_schema.KEY_COLUMN_USAGE
      WHERE TABLE_SCHEMA = #{quote(database)}
        AND TABLE_NAME = #{quote(table_name)}
        AND CONSTRAINT_NAME = 'PRIMARY'
      ORDER BY ORDINAL_POSITION
      LIMIT 1
    SQL
  end

  def simple_primary_key(target_model)
    primary_key = target_model.primary_key
    return nil if primary_key.blank? || primary_key.is_a?(Array)

    primary_key.to_s
  end

  def numeric_column?(database, table_name, column_name)
    data_type = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT DATA_TYPE
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = #{quote(database)}
        AND TABLE_NAME = #{quote(table_name)}
        AND COLUMN_NAME = #{quote(column_name)}
      LIMIT 1
    SQL
    %w[tinyint smallint mediumint int bigint].include?(data_type.to_s.downcase)
  end

  def migratable_table?(source_table, target_model)
    table_exists?(SOURCE_DB, source_table) && table_exists?(TARGET_DB, target_model.table_name)
  end

  def table_exists?(database, table_name)
    ActiveRecord::Base.connection.select_value(<<~SQL).to_i.positive?
      SELECT COUNT(*)
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = #{quote(database)}
        AND TABLE_NAME = #{quote(table_name)}
    SQL
  end

  def column_names(database, table_name)
    ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT COLUMN_NAME
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = #{quote(database)}
        AND TABLE_NAME = #{quote(table_name)}
      ORDER BY ORDINAL_POSITION
    SQL
  end

  def skip_table_message(table_name, reason)
    puts "\nSkipping #{table_name}: #{reason}"
  end

  def table_ref(database, table_name)
    "#{q(database)}.#{q(table_name)}"
  end

  def q(identifier)
    "`#{identifier.to_s.gsub('`', '``')}`"
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end

MahisProToDevMigrator.run if __FILE__ == $PROGRAM_NAME
