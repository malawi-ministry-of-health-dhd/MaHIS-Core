require 'active_record'
require 'json'
require 'psych'
require 'parallel'
require 'sys/proctable'
require 'sys/cpu'
require 'sys/filesystem'
require 'sys/memory'
require 'csv'

include Sys

NON_RESET_MODELS = %w[Patient DrugOrder GlobalProperty UserRole UserProperty DrugIngredient
                      LimsAcknowledgementStatus].freeze

# Define Form model if it doesn't exist
unless defined?(Form)
  class Form < ApplicationRecord
    self.table_name = 'form'
    self.primary_key = 'form_id'
  end
end
# @orphaned_order_id = []

# Retrieve location_id using the new workflow
def get_validated_location_id(source_db)
  puts 'Retrieving location_id from source database...'

  # Step 1: Get location_id from source database global_property
  source_location_result = ActiveRecord::Base.connection.select_one(
    "SELECT property_value FROM #{source_db}.global_property WHERE property = 'current_health_center_id' LIMIT 1"
  )

  unless source_location_result
    puts "✗ Error: 'current_health_center_id' not found in source database global_property table."
    puts 'Falling back to manual entry...'
    return get_validated_location_id_manual
  end

  source_location_id = source_location_result['property_value'].to_i
  puts "✓ Source location_id retrieved: #{source_location_id}"

  # Step 2: Look up facility_code in locations_x_facilities.csv
  csv_path = Rails.root.join('db', 'locations_x_facilities.csv')
  unless File.exist?(csv_path)
    puts "✗ Error: CSV file not found at #{csv_path}"
    puts 'Falling back to manual entry...'
    return get_validated_location_id_manual
  end

  facility_code = nil
  CSV.foreach(csv_path, headers: true) do |row|
    if row['location_id'].to_i == source_location_id
      facility_code = row['facility_code']
      puts "✓ Facility code found: #{facility_code} (#{row['facility_name']})"
      break
    end
  end

  unless facility_code
    puts "✗ Error: Location ID #{source_location_id} not found in locations_x_facilities.csv"
    puts 'Falling back to manual entry...'
    return get_validated_location_id_manual
  end

  # Step 3: Look up location_id in location_attributes by facility_code
  facility_code_type_id = LocationAttributeType.find_by(name: 'Facility Code')&.location_attribute_type_id
  unless facility_code_type_id
    puts "✗ Error: 'Facility Code' attribute type not found in location_attribute_type table"
    puts 'Falling back to manual entry...'
    return get_validated_location_id_manual
  end

  location_attribute = LocationAttribute.find_by(
    attribute_type_id: facility_code_type_id,
    value_reference: facility_code
  )

  unless location_attribute
    puts "✗ Error: Facility code '#{facility_code}' not found in location_attributes table"
    puts 'Falling back to manual entry...'
    return get_validated_location_id_manual
  end

  target_location_id = location_attribute.location_id
  location = Location.find_by_location_id(target_location_id)

  unless location
    puts "✗ Error: Location ID #{target_location_id} not found in locations table"
    puts 'Falling back to manual entry...'
    return get_validated_location_id_manual
  end

  puts "✓ Target location found: #{location.name} (ID: #{target_location_id})"

  # Auto-confirm if running non-interactively
  if ENV['AUTO_CONFIRM'] == 'true'
    puts 'Auto-confirming (AUTO_CONFIRM=true)'
    return target_location_id
  end

  print 'Is this correct? (yes/no): '
  confirmation = $stdin.gets.chomp.downcase

  if %w[yes y].include?(confirmation)
    target_location_id
  else
    puts 'User rejected automatic location mapping.'
    puts 'Falling back to manual entry...'
    get_validated_location_id_manual
  end
end

# Manual location_id entry (fallback method)
def get_validated_location_id_manual
  loop do
    print 'Enter the location_id for the site: '
    location_id = gets.chomp.to_i

    if location_id <= 0
      puts 'Invalid location_id. Please enter a positive integer.'
      next
    end

    location = Location.find_by_location_id(location_id)
    if location
      puts "✓ Location found: #{location.name} (ID: #{location_id})"
      print 'Is this correct? (yes/no): '
      confirmation = gets.chomp.downcase
      return location_id if %w[yes y].include?(confirmation)

      puts 'Please enter the correct location_id.'
    else
      puts "✗ Location with ID #{location_id} not found in the database."
      print 'Would you like to try again? (yes/no): '
      retry_choice = gets.chomp.downcase
      exit unless %w[yes y].include?(retry_choice)
    end
  end
end

# Load Database Configuration
database_config = Psych.load(File.read('config/database.yml'), aliases: true).freeze
source_db = database_config['centralized_source_db']['database']

# Optimize connection pool for parallel processing
optimal_thread_count = [Parallel.physical_processor_count * 2, 10].min
ActiveRecord::Base.establish_connection(
  database_config[Rails.env].merge(
    'pool' => optimal_thread_count + 5,
    'reaping_frequency' => 10,
    'checkout_timeout' => 10
  )
)
SITE_ID = get_validated_location_id(source_db)
SITE_USER_MAPPING = Rails.root.join('log', "users_mapping_#{SITE_ID}.json")
File.write(SITE_USER_MAPPING, '{}') unless File.exist?(SITE_USER_MAPPING)

# Load concept mapping file for fast lookups
CONCEPT_MAPPING_FILE = Rails.root.join('db', 'concept_id_mapping.json')
if File.exist?(CONCEPT_MAPPING_FILE)
  puts 'Loading concept mapping from file...'
  concept_mapping_data = JSON.parse(File.read(CONCEPT_MAPPING_FILE))
  CONCEPT_ID_MAP = concept_mapping_data['mapping'].transform_keys(&:to_i).transform_values(&:to_i)
  puts "✓ Loaded #{CONCEPT_ID_MAP.size} concept mappings"
else
  puts '⚠ Warning: Concept mapping file not found. Run bin/generate_concept_mapping.rb first'
  puts '  Migration will be slower without pre-built concept mappings'
  CONCEPT_ID_MAP = {}
end

Location.current = Location.find_by_location_id(SITE_ID)
user = User.unscoped.first
user.location_id = SITE_ID
User.current = user
CURRENT_USER = User.current

# Initialize caches for frequently accessed mappings to reduce database queries
USER_ID_CACHE = {}
PERSON_ID_CACHE = {}
ENCOUNTER_ID_CACHE = {}
ORDER_ID_CACHE = {}
PROGRAM_ID_CACHE = {}
OBS_ID_CACHE = {}

# Mutex for thread-safe cache updates
CACHE_MUTEX = Mutex.new

def prepare_centralized_db
  puts 'Preparing Centralized database for migration...'

  begin
    if ActiveRecord::Base.connection.index_name_exists?(:global_property, :global_property_uuid_index)
      ActiveRecord::Base.connection.execute <<~SQL
        ALTER TABLE global_property DROP INDEX global_property_uuid_index;
      SQL
      puts '✓ Dropped global_property UUID index'
    end
  rescue StandardError => e
    puts "⚠ Could not drop global_property index: #{e.message}"
  end

  begin
    if ActiveRecord::Base.connection.primary_key(:global_property)
      ActiveRecord::Base.connection.execute <<~SQL
        ALTER TABLE global_property DROP PRIMARY KEY;
      SQL
      puts '✓ Dropped global_property primary key'
    end
  rescue StandardError => e
    puts "⚠ Could not drop global_property primary key: #{e.message}"
  end

  begin
    foreign_keys = ActiveRecord::Base.connection.foreign_keys(:drug_ingredient).map(&:name)

    if foreign_keys.include?('ingredient')
      ActiveRecord::Base.connection.execute <<~SQL
        ALTER TABLE drug_ingredient DROP FOREIGN KEY ingredient;
      SQL
      puts '✓ Dropped drug_ingredient ingredient foreign key'
    end

    if foreign_keys.include?('combination_drug')
      ActiveRecord::Base.connection.execute <<~SQL
        ALTER TABLE drug_ingredient DROP FOREIGN KEY combination_drug;
      SQL
      puts '✓ Dropped drug_ingredient combination_drug foreign key'
    end

    if ActiveRecord::Base.connection.primary_key(:drug_ingredient)
      ActiveRecord::Base.connection.execute <<~SQL
        ALTER TABLE drug_ingredient DROP PRIMARY KEY;
      SQL
      puts '✓ Dropped drug_ingredient primary key'
    end
  rescue StandardError => e
    puts "⚠ Could not modify drug_ingredient table: #{e.message}"
  end

  puts 'Database preparation complete!'
end

# Query Helper
def query_with_columns(table_name, where_clause = nil, limit = nil, offset = nil, target_model = nil)
  # If target_model provided, only select columns that exist in target schema
  if target_model
    target_columns = target_model.column_names
    source_columns = ActiveRecord::Base.connection.columns(table_name).map(&:name)
    common_columns = target_columns & source_columns
    column_list = common_columns.join(', ')
    query = "SELECT #{column_list} FROM #{table_name}"
  else
    query = "SELECT * FROM #{table_name}"
  end

  query += " WHERE #{where_clause}" if where_clause
  query += " LIMIT #{limit}" if limit
  query += " OFFSET #{offset}" if offset

  ActiveRecord::Base.connection.select_all(query).to_a
end

# Dynamically determine optimal thread count based on system load
def optimal_threads
  memory_stats = Sys::Memory
  free_memory = memory_stats.total - memory_stats.used
  free_memory_gb = free_memory.to_f / (1024**3)
  memory_usage = (memory_stats.used.to_f / memory_stats.total) * 100

  num_cores = Parallel.physical_processor_count
  max_threads = num_cores - 1

  # Use load_avg as a fallback
  cpu_usage = Sys::CPU.load_avg[0] / num_cores * 100

  disk_usage = Sys::Filesystem.stat('/').percent_used

  thread_boost = [(free_memory / (memory_stats.total * 0.1)).to_i, 4].min
  dynamic_max_threads = num_cores + thread_boost
  min_threads = [(num_cores * 0.25).to_i, 2].max

  thread_count = if cpu_usage < 70 && free_memory > (memory_stats.total * 0.2)
                   [max_threads, dynamic_max_threads].min
                 elsif cpu_usage > 80 || free_memory < (memory_stats.total * 0.05)
                   min_threads
                 else
                   num_cores
                 end

  puts "Using #{thread_count} threads | CPU: #{cpu_usage.round(2)}% | RAM: #{memory_usage.round(2)}% | Free RAM: #{free_memory_gb.round(2)} GB | Disk: #{disk_usage.round(2)}%"

  thread_count
end

# Determine optimal batch size based on table size and available memory
def determine_optimal_batch_size(source_db, table_name)
  # Convert table_name to string and extract just the table name without schema prefix
  table_name_str = table_name.to_s
  bare_table_name = table_name_str.include?('.') ? table_name_str.split('.').last : table_name_str

  # Get table row count
  row_count = ActiveRecord::Base.connection.select_one(
    "SELECT COUNT(*) AS count FROM #{source_db}.#{bare_table_name}"
  )['count'].to_i

  # Get approximate row size in bytes
  table_stats = ActiveRecord::Base.connection.select_one(
    "SELECT
      ROUND(((data_length + index_length)), 2) AS size_bytes,
      table_rows
    FROM information_schema.TABLES
    WHERE table_schema = '#{source_db}'
    AND table_name = '#{bare_table_name}'"
  )

  avg_row_size = if table_stats && table_stats['table_rows'].to_i > 0
                   table_stats['size_bytes'].to_f / table_stats['table_rows'].to_f
                 else
                   1000 # Default 1KB per row if stats unavailable
                 end

  # Calculate optimal batch size based on available memory (aim for ~100MB per batch)
  memory_stats = Sys::Memory
  memory_stats.total
  memory_stats.used
  target_batch_memory = 100 * 1024 * 1024 # 100MB

  optimal_batch = (target_batch_memory / avg_row_size).to_i

  # Adaptive sizing based on table size
  batch_size = case row_count
               when 0..1000
                 [row_count, optimal_batch].min # Small tables: process all at once
               when 1001..10_000
                 [5_000, optimal_batch].min
               when 10_001..100_000
                 [25_000, optimal_batch].min
               when 100_001..1_000_000
                 [50_000, optimal_batch].min
               else
                 [100_000, optimal_batch].min # Very large tables
               end

  [batch_size, 1000].max # Minimum 1000 rows per batch
end

# Process in Batches with Dynamic Threads and Percentage Tracking
def process_in_batches(source_db, table_name, batch_size = nil, target_model = nil)
  # Convert table_name to string
  table_name_str = table_name.to_s

  # Adaptive batch sizing based on table characteristics
  batch_size ||= determine_optimal_batch_size(source_db, table_name_str)
  # Test mode: only process 10 records per table
  test_limit = ENV['TEST_MODE'] == 'true' ? 10 : nil

  if test_limit
    # In test mode, only process one batch
    batch_ranges = [[0, test_limit]]
  elsif %w[global_property user_role user_property].include?(table_name_str)
    batch_ranges = [[0, 100_000]]
  else
    full_table_name = "#{source_db}.#{table_name_str}"
    column_name = ActiveRecord::Base.connection.columns(full_table_name).first.name
    min_max = ActiveRecord::Base.connection.select_one("SELECT MIN(#{column_name}) AS min_id,
                                                        MAX(#{column_name})
                                                        AS max_id FROM #{full_table_name}")
    min_id = min_max['min_id'].to_i
    max_id = min_max['max_id'].to_i
    batch_ranges = (min_id..max_id).each_slice(batch_size).to_a
  end

  processed_records = 0
  total_records = if test_limit
                    [ActiveRecord::Base.connection.select_one("SELECT COUNT(*) AS count
                                                            FROM #{source_db}.#{table_name_str}")['count'].to_i, test_limit].min
                  else
                    ActiveRecord::Base.connection.select_one("SELECT COUNT(*) AS count
                                                            FROM #{source_db}.#{table_name_str}")['count'].to_i
                  end

  puts "🧪 TEST MODE: Limiting to #{test_limit} records per table" if test_limit
  num_threads = test_limit ? 1 : optimal_threads
  puts "Using #{num_threads} threads for processing #{table_name_str}..."

  Parallel.each(batch_ranges, in_threads: num_threads) do |batch_range|
    # Use connection pool to manage connections properly in threads
    ActiveRecord::Base.connection_pool.with_connection do
      records = if test_limit
                  # In test mode, just get first N records without ID range filtering
                  query_with_columns("#{source_db}.#{table_name_str}", nil, test_limit, nil, target_model)
                elsif %w[global_property user_role user_property].include?(table_name_str)
                  query_with_columns("#{source_db}.#{table_name_str}", nil, nil, nil, target_model)
                else
                  full_table_name = "#{source_db}.#{table_name_str}"
                  column_name = ActiveRecord::Base.connection.columns(full_table_name).first.name
                  query_with_columns(full_table_name, "#{column_name} >= #{batch_range.first}
                                                AND #{column_name} <= #{batch_range.last}", nil, nil, target_model)
                end

      next if records.blank?

      yield(records)

      processed_records += records.size
      percentage = ((processed_records.to_f / total_records) * 100).round(2)
      puts "Processing #{table_name_str}: #{percentage}% complete (#{processed_records}/#{total_records})"
    end
  ensure
    # Explicitly close and release this thread's connection when done
    if ActiveRecord::Base.connection_pool.active_connection?
      ActiveRecord::Base.connection.close
      ActiveRecord::Base.connection_pool.release_connection
    end
  end
ensure
  # Clear any lingering connections after processing
  ActiveRecord::Base.connection_pool.release_connection
end

# Populate Person
def populate_person(person_data, source_db)
  person_data.symbolize_keys!
  person_data[:person_id] = nil

  %i[changed_by creator voided_by].each do |key|
    person_data[key] = get_new_user_id(person_data[key], source_db) || 1 if person_data[key]
  end

  existing_person = Person.unscoped.find_by(uuid: person_data[:uuid])
  return existing_person.person_id if existing_person

  new_person = Person.new(person_data)
  new_person.save!(validate: false)
  new_person.person_id
end

# Generic Populate Function with Percentage Tracking
def populate_records(source_table, target_model, source_db, foreign_keys = {})
  process_in_batches(source_db, source_table, nil, target_model) do |records|
    records.each(&:symbolize_keys!)
    # Fetch only the records that exist in the current batch
    record_keys = case target_model.to_s
                  when 'Patient'
                    patient_ids = records.map { |r| r[:patient_id] }
                    uuids = query_with_columns("#{source_db}.person",
                                               "person_id in (#{patient_ids.join(', ')})").pluck('uuid')
                    Person.unscoped.where(uuid: uuids).pluck(:person_id)
                  when 'DrugOrder'
                    order_ids = records.map { |r| r[:order_id] }
                    uuids = query_with_columns("#{source_db}.orders",
                                               "order_id in (#{order_ids.join(', ')})").pluck('uuid')
                    Order.unscoped.where(uuid: uuids).pluck(:order_id)
                  when 'GlobalProperty'
                    records.map { |r| r[:property] }
                  when 'LimsAcknowledgementStatus'
                    records.map { |r| r[:order_id] }
                  when 'UserRole'
                    records.map { |r| [r[:role], r[:user_id]] }
                  when 'UserProperty'
                    records.map { |r| [r[:user_id], r[:property]] }
                  when 'DrugIngredient'
                    records.map { |r| [r[:concept_id], r[:ingredient_id]] }
                  when 'PharmacyStockBalance', 'PharmacyStockVerification', 'Pharmacies'
                    # These tables skip duplicate checking - always insert
                    []
                  else
                    records.map { |r| r[:uuid] }
                  end

    existing_keys = case target_model.to_s
                    when 'Patient'
                      target_model.unscoped.where(patient_id: record_keys).pluck(:patient_id).to_set
                    when 'DrugOrder'
                      target_model.unscoped.where(order_id: record_keys).pluck(:order_id).to_set
                    when 'GlobalProperty'
                      target_model.unscoped.where(property: record_keys).pluck(:property).to_set
                    when 'LimsAcknowledgementStatus'
                      target_model.unscoped.where(order_id: record_keys).pluck(:order_id).to_set
                    when 'UserRole'
                      target_model.unscoped.where(role: record_keys.map(&:first), user_id: record_keys.map(&:last))
                                  .pluck(:role, :user_id).map { |r, u| [r, u] }.to_set
                    when 'UserProperty'
                      target_model.unscoped.where(user_id: record_keys.map(&:first), property: record_keys.map(&:last))
                                  .pluck(:user_id, :property).map { |u, p| [u, p] }.to_set
                    when 'DrugIngredient'
                      target_model.unscoped.where(concept_id: record_keys.map(&:first), ingredient_id: record_keys.map(&:last))
                                  .pluck(:concept_id, :ingredient_id).map do |c, i|
                        [c, i]
                      end.to_set
                    when 'PharmacyStockBalance', 'PharmacyStockVerification', 'Pharmacies'
                      Set.new
                    else
                      target_model.unscoped.where(uuid: record_keys).pluck(:uuid).to_set
                    end

    # Update foreign key mappings
    # Skip obs_group_id for Observations - will be updated in separate batch later
    keys_to_process = if target_model.to_s == 'Observation'
                        foreign_keys.reject { |key, _| key == :obs_group_id }
                      else
                        foreign_keys
                      end

    keys_to_process.each do |foreign_key, mapping_method|
      records = send(mapping_method, records, foreign_key, source_db)
    end

    insertable_records = records.reject do |record|
      case target_model.to_s
      when 'Patient'
        existing_keys.include?(record[:patient_id])
      when 'DrugOrder'
        existing_keys.include?(record[:order_id]) || record[:order_id].blank?
      when 'GlobalProperty'
        existing_keys.include?(record[:property])
      when 'LimsAcknowledgementStatus'
        existing_keys.include?(record[:order_id])
      when 'UserRole'
        existing_keys.include?([record[:role], record[:user_id]])
      when 'UserProperty'
        existing_keys.include?([record[:user_id], record[:property]])
      when 'DrugIngredient'
        existing_keys.include?([record[:concept_id], record[:ingredient_id]])
      when 'PharmacyStockBalance', 'PharmacyStockVerification', 'Pharmacies'
        false # Never reject - always insert
      else
        existing_keys.include?(record[:uuid])
      end
    end

    next if insertable_records.blank?

    # Set location_id for tables that have this column
    if %w[GlobalProperty PharmacyBatch PatientIdentifier PatientProgram Encounter
          Observation].include?(target_model.to_s)
      location_id_value = target_model.to_s == 'GlobalProperty' ? SITE_ID.to_s : SITE_ID
      insertable_records.each do |record|
        record[:location_id] = location_id_value if record.key?(:location_id)
      end
    end

    # For Observations, temporarily set obs_group_id to NULL - will be updated by update_group_obs_ids
    if target_model.to_s == 'Observation'
      insertable_records.each do |record|
        record[:obs_group_id] = nil if record.key?(:obs_group_id)
      end
    end

    # Filter out records with nil required foreign keys
    original_count = insertable_records.size
    if target_model.to_s == 'Observation'
      insertable_records.reject! { |r| r[:concept_id].nil? }
      filtered_count = original_count - insertable_records.size
      puts "  Filtered #{filtered_count} obs records with nil concept_id" if filtered_count > 0
    elsif target_model.to_s == 'Order'
      insertable_records.reject! { |r| r[:concept_id].nil? || r[:order_type_id].nil? }
      filtered_count = original_count - insertable_records.size
      puts "  Filtered #{filtered_count} order records with nil concept_id or order_type_id" if filtered_count > 0
    end

    next if insertable_records.blank?

    # Reset primary key if necessary
    if insertable_records.first.keys.include?(:date_created)
      insertable_records.each do |record|
        record[target_model.primary_key.to_sym] = nil unless NON_RESET_MODELS.include?(target_model.to_s)
        record[:date_created] = begin
          record[:date_created].to_datetime
        rescue StandardError
          '1900-01-01 00:00:00'
        end
      end
    else
      insertable_records.each do |record|
        record[target_model.primary_key.to_sym] = nil unless NON_RESET_MODELS.include?(target_model.to_s)
        record.delete(:id) if target_model.to_s == 'GlobalProperty'
      end
    end
    User.current = CURRENT_USER
    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 0')
      begin
        target_model.unscoped.insert_all!(insertable_records.compact)
      rescue ActiveRecord::RecordNotUnique, Mysql2::Error => e
        # Skip duplicate entries - they already exist
        if e.message.include?('Duplicate entry')
          puts "Mysql2::Error: #{e.message}"
        elsif e.message.include?('cannot be null') || e.message.include?('syntax')
          # Try to identify and remove problematic records, then retry
          puts "⚠ Error in #{target_model}: #{e.message} - Skipping batch"
        else
          puts "❌ Error inserting into #{target_model}: #{e.message}"
          puts e.backtrace.first(5).join("\n")
        end
      rescue StandardError => e
        puts "❌ Error inserting into #{target_model}: #{e.message}"
        puts e.backtrace.first(5).join("\n")
      end
      ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 1')
    end
  end
end

# User Migration with Percentage Tracking
def populate_users(source_db)
  admin_user = query_with_columns("#{source_db}.users", 'user_id = 1').first
  if User.unscoped.exists?(uuid: admin_user['uuid'])
    admin_user = User.unscoped.find_by(uuid: admin_user['uuid'])
  else
    next_user_id = User.unscoped.maximum(:user_id) + 1
    admin_user['user_id'] = next_user_id
    admin_user['creator'] = next_user_id
    admin_user['changed_by'] = next_user_id
    admin_user['person_id'] = create_user_person(admin_user.symbolize_keys, source_db)
    admin_user['location_id'] = SITE_ID
    admin_user = User.new(admin_user)
    admin_user.save!(validate: false)
  end

  process_in_batches(source_db, 'users') do |users|
    insertable_records = users.map do |user|
      user.symbolize_keys!

      next if User.unscoped.exists?(uuid: user[:uuid])

      user[:user_id] = nil

      %i[changed_by creator retired_by].each do |key|
        user[key] = get_new_user_id(user[key], source_db) || admin_user['user_id'] if user[key]
      end

      user[:person_id] = create_user_person(user, source_db) if user[:person_id]

      # Set location_id from SITE_ID
      user[:location_id] = SITE_ID

      user
    end
    next if insertable_records.compact.blank?

    User.current = CURRENT_USER
    User.unscoped.insert_all!(insertable_records.compact)
  end
end

# Helper Methods with Caching
def fetch_new_ids(records, source_db, table_name, id_column, model, new_id_key)
  old_ids = records.compact.map { |record| record[new_id_key] }.uniq.compact

  return records if old_ids.blank?

  # Check cache first based on model type
  cache = case model.to_s
          when 'User' then USER_ID_CACHE
          when 'Person' then PERSON_ID_CACHE
          when 'Encounter' then ENCOUNTER_ID_CACHE
          when 'Order' then ORDER_ID_CACHE
          when 'PatientProgram' then PROGRAM_ID_CACHE
          when 'Observation' then OBS_ID_CACHE
          end

  # Build mapping from cache and database
  cached_mappings = {}
  uncached_ids = []

  if cache
    CACHE_MUTEX.synchronize do
      old_ids.each do |id|
        if cache[id]
          cached_mappings[id] = cache[id]
        else
          uncached_ids << id
        end
      end
    end
  else
    uncached_ids = old_ids
  end

  # Fetch uncached IDs from database
  uuid_map = {}
  if uncached_ids.any?
    uuid_mapping = query_with_columns(
      "#{source_db}.#{table_name}",
      "#{id_column} IN (#{uncached_ids.join(',')})"
    ).index_by { |row| row[id_column.to_s] }

    uuid_map = model.unscoped.where(uuid: uuid_mapping.values.map { |row| row['uuid'] })
                    .pluck(:uuid, id_column)
                    .to_h

    # Update cache with new mappings
    if cache
      CACHE_MUTEX.synchronize do
        uncached_ids.each do |old_id|
          uuid = uuid_mapping[old_id]&.fetch('uuid')
          new_id = uuid_map[uuid]
          cache[old_id] = new_id if new_id
        end
      end
    end
  end

  # Apply mappings to records
  records.compact.each do |record|
    next if record[new_id_key].blank?

    begin
      new_id = cached_mappings[record[new_id_key]]
      unless new_id
        uuid = begin
          uuid_mapping[record[new_id_key]]&.fetch('uuid')
        rescue StandardError
          nil
        end
        new_id = uuid_map[uuid] if uuid
      end

      raise "Mapping not found for #{new_id_key}: #{record[new_id_key]}" unless new_id

      record[new_id_key] = new_id
    rescue StandardError => e
      if %i[creator voided_by changed_by].include?(new_id_key)
        record[new_id_key] = cached_mappings.values.first || uuid_map.values.first || 1
      elsif new_id_key == :obs_group_id
        # For obs_group_id, set to nil initially - will be updated later
        record[new_id_key] = nil
      elsif %i[order_id patient_id encounter_id].include?(new_id_key)
        records.delete(record)
      else
        puts "Error mapping #{new_id_key} for #{model}: #{e.message}"
        records.delete(record)
      end
    end
  end
  records
end

# Map IDs by name field instead of UUID
def fetch_new_ids_by_name(records, source_db, table_name, id_column, name_column, model, new_id_key)
  old_ids = records.compact.map { |record| record[new_id_key] }.uniq.compact

  return records if old_ids.blank?

  # Get source records with their names
  name_mapping = query_with_columns(
    "#{source_db}.#{table_name}",
    "#{id_column} IN (#{old_ids.join(',')})"
  ).index_by { |row| row[id_column.to_s] }

  # Get destination records by name and build a name-to-id map
  names = name_mapping.values.map { |row| row[name_column.to_s]&.strip }.compact.uniq
  return records if names.blank?

  # Escape single quotes in names for SQL safety
  escaped_names = names.map { |name| "'#{ActiveRecord::Base.connection.quote_string(name)}'" }.join(',')

  # Build a case-insensitive name map: lowercase name => [actual_name, id]
  name_to_id_map = model.unscoped.where("LOWER(TRIM(#{name_column})) IN (#{escaped_names.downcase})")
                        .pluck(name_column, id_column)
                        .map { |name, id| [name.downcase.strip, id] }
                        .to_h

  records.compact.each do |record|
    next if record[new_id_key].blank?

    begin
      source_name = name_mapping[record[new_id_key]][name_column.to_s]&.strip
      destination_id = name_to_id_map[source_name&.downcase]

      if destination_id
        record[new_id_key] = destination_id
      else
        puts "⚠ Warning: No match found for #{table_name} with name '#{source_name}'"
        if %i[creator voided_by changed_by].include?(new_id_key)
          record[new_id_key] = name_to_id_map.values.first
        else
          records.delete(record)
        end
      end
    rescue StandardError => e
      puts "Error mapping #{new_id_key} for #{table_name}: #{e.message}"
      if %i[creator voided_by changed_by].include?(new_id_key)
        record[new_id_key] = name_to_id_map.values.first
      else
        records.delete(record)
      end
    end
  end
  records
end

def get_new_user_id(old_user_id, source_db)
  return unless old_user_id

  user_uuid = query_with_columns("#{source_db}.users", "user_id = #{old_user_id}").first['uuid']
  User.unscoped.find_by(uuid: user_uuid)&.id
end

def create_user_person(user, source_db)
  person_data = query_with_columns("#{source_db}.person", "person_id = #{user[:person_id]}").first
  populate_person(person_data, source_db)
end

def get_encounter_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'encounter', :encounter_id, Encounter, key)
end

def get_new_user_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'users', :user_id, User, key)
end

def get_person_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'person', :person_id, Person, key)
end

def get_order_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'orders', :order_id, Order, key)
end

def get_obs_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'obs', :obs_id, Observation, key)
end

def get_program_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'patient_program', :patient_program_id, PatientProgram, key)
end

def get_encounter_type_ids(records, key, source_db)
  fetch_new_ids_by_name(records, source_db, 'encounter_type', :encounter_type_id, :name, EncounterType, key)
end

def get_concept_ids(records, key, _source_db)
  # Use pre-built concept mapping for fast lookups
  old_ids = records.compact.map { |record| record[key] }.uniq.compact

  return records if old_ids.blank?

  # Map using pre-built hash
  records_to_remove = []

  records.compact.each do |record|
    next if record[key].blank?

    source_concept_id = record[key]
    destination_concept_id = CONCEPT_ID_MAP[source_concept_id]

    if destination_concept_id
      record[key] = destination_concept_id
    elsif %i[value_coded discontinued_reason].include?(key)
      # For optional concept fields, set to nil; for required ones, mark for removal
      record[key] = nil
    else
      records_to_remove << record
    end
  end

  # Remove records that couldn't be mapped
  records_to_remove.each { |r| records.delete(r) }

  records
end

def get_order_type_ids(records, key, source_db)
  fetch_new_ids_by_name(records, source_db, 'order_type', :order_type_id, :name, OrderType, key)
end

def get_form_ids(records, key, source_db)
  fetch_new_ids_by_name(records, source_db, 'form', :form_id, :name, Form, key)
end

def get_drug_ids(records, key, source_db)
  fetch_new_ids_by_name(records, source_db, 'drug', :drug_id, :name, Drug, key)
end

def get_program_workflow_ids(records, key, source_db)
  fetch_new_ids_by_name(records, source_db, 'program', :program_id, :name, Program, key)
end

def get_new_report_design_id(records, key, source_db)
  fetch_new_ids(records, source_db, 'reporting_report_design', :id, Report, key)
end

def get_location_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'location', :location_id, Location, key)
end

def get_stock_verification_ids(records, key, source_db)
  fetch_new_ids(records, source_db, 'pharmacy_stock_verifications', :id, PharmacyStockVerification, key)
end

def create_users_persons(records, source_db)
  person_ids = records.map { |record| record[:person_id] }.compact

  person_data = query_with_columns(
    "#{source_db}.person",
    "person_id IN (#{person_ids.join(',')})"
  ).index_by { |row| row['person_id'] }

  records.each do |record|
    if person_data[record[:person_id]]
      record[:person_data] =
        populate_person(person_data[record[:person_id]], source_db)
    end
  end

  records
end

def update_group_obs_ids(source_db, foreign_keys = {})
  puts 'Starting obs_group_id update...'

  # Use adaptive batch size for better performance
  limit = determine_optimal_batch_size(source_db, 'obs')
  offset = 0
  total_processed = 0
  total_records = ActiveRecord::Base.connection
                                    .select_one("SELECT COUNT(*) AS count
                                    FROM #{source_db}.obs WHERE obs_group_id IS NOT NULL")['count'].to_i

  return if total_records == 0

  puts "Found #{total_records} observations with obs_group_id to update"

  # Drop existing temp table if exists and create fresh
  ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_obs_update')
  ActiveRecord::Base.connection.execute(<<-SQL)
    CREATE TABLE temp_obs_update (
      uuid CHAR(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin PRIMARY KEY,
      obs_group_id INT,
      INDEX idx_obs_group_id (obs_group_id)
    ) ENGINE=InnoDB;
  SQL

  batch_update_threshold = 50_000 # Apply updates every 50k records to avoid huge temp table
  current_batch_size = 0

  loop do
    source_obs_grouped = query_with_columns("#{source_db}.obs", 'obs_group_id IS NOT NULL', limit, offset)
    break if source_obs_grouped.blank?

    source_obs_grouped.each(&:symbolize_keys!)

    # Fetch and map foreign keys in bulk - use caching
    mapped_records = source_obs_grouped
    foreign_keys.each do |foreign_key, mapping_method|
      mapped_records = send(mapping_method, mapped_records, foreign_key, source_db)
    end

    # Prepare batch updates - filter out nil values
    updates = mapped_records.map do |record|
      {
        uuid: record[:uuid],
        obs_group_id: record[:obs_group_id]
      }
    end.reject { |r| r[:uuid].blank? || r[:obs_group_id].nil? }

    if updates.any?
      # Use INSERT IGNORE for better performance
      values = updates.map { |r| "('#{r[:uuid]}', #{r[:obs_group_id]})" }.join(', ')
      ActiveRecord::Base.connection.execute("INSERT IGNORE INTO temp_obs_update (uuid, obs_group_id) VALUES #{values}")

      total_processed += updates.size
      current_batch_size += updates.size

      # Apply updates incrementally to avoid huge temp table
      if current_batch_size >= batch_update_threshold
        puts 'Applying batch obs_group_id updates...'
        ActiveRecord::Base.connection.execute('UPDATE obs o
            JOIN temp_obs_update t ON o.uuid = t.uuid
            SET o.obs_group_id = t.obs_group_id')
        ActiveRecord::Base.connection.execute('TRUNCATE TABLE temp_obs_update')
        current_batch_size = 0
      end
    end

    offset += limit
    percentage = ((total_processed.to_f / total_records) * 100).round(2)
    puts "Updating obs_group_id: #{percentage}% complete (#{total_processed}/#{total_records})"
  end

  # Perform final update for any remaining records
  remaining_count = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM temp_obs_update').to_i
  if remaining_count > 0
    puts 'Applying final obs_group_id updates to obs table...'
    ActiveRecord::Base.connection.execute('UPDATE obs o
        JOIN temp_obs_update t ON o.uuid = t.uuid
        SET o.obs_group_id = t.obs_group_id;')
  end
  puts '✓ obs_group_id update complete'
ensure
  ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_obs_update;')
end

# Main Execution
prepare_centralized_db
populate_users(source_db)
def populate_group(group)
  Parallel.each(group, in_threads: optimal_threads) do |(table, model, source_db, dependencies)|
    ActiveRecord::Base.connection_pool.with_connection do
      populate_records(table, model, source_db, dependencies)
    end
  rescue StandardError => e
    puts "❌ Error processing #{table}: #{e.message}"
    puts e.backtrace.first(10).join("\n")
  ensure
    # Explicitly close and release this thread's connection after table completes
    if ActiveRecord::Base.connection_pool.active_connection?
      ActiveRecord::Base.connection.close
      ActiveRecord::Base.connection_pool.release_connection
    end
  end
ensure
  # Disconnect all remaining connections from pool after group completes
  ActiveRecord::Base.connection_pool.disconnect!
end

if __FILE__ == $0
  group1_models = {
    user_role: [UserRole, {
      user_id: :get_new_user_ids
    }],
    user_property: [UserProperty, {
      user_id: :get_new_user_ids
    }],
    global_property: [GlobalProperty, {}],
    person: [Person, {
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    reporting_report_design: [Report, {
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      retired_by: :get_new_user_ids
    }],
    pharmacies: [Pharmacies, {}],
    pharmacy_batch_items: [PharmacyBatchItem, {
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    pharmacy_batches: [PharmacyBatch, {
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    pharmacy_stock_balances: [PharmacyStockBalance, {}],
    pharmacy_stock_verifications: [PharmacyStockVerification, {}],
    drug_ingredient: [DrugIngredient, {}]
  }

  group2_models = {
    relationship: [Relationship, {
      creator: :get_new_user_ids,
      voided_by: :get_new_user_ids,
      person_a: :get_person_ids,
      person_b: :get_person_ids
    }],
    person_name: [PersonName, {
      person_id: :get_person_ids,
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    person_address: [PersonAddress, {
      person_id: :get_person_ids,
      creator: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    person_attribute: [PersonAttribute, {
      person_id: :get_person_ids,
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    patient: [Patient, {
      patient_id: :get_person_ids,
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    reporting_report_design_resource: [ReportingReportDesignResource, {
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      retired_by: :get_new_user_ids,
      report_design_id: :get_new_report_design_id
    }],
    pharmacy_obs: [Pharmacy, {
      creator: :get_new_user_ids,
      voided_by: :get_new_user_ids,
      dispensation_obs_id: :get_obs_ids,
      stock_verification_id: :get_stock_verification_ids
    }]
  }

  group3_models = {
    patient_identifier: [PatientIdentifier, {
      patient_id: :get_person_ids,
      creator: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }],
    patient_program: [PatientProgram, {
      patient_id: :get_person_ids,
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids,
      program_id: :get_program_workflow_ids
    }],
    encounter: [Encounter, {
      patient_id: :get_person_ids,
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids,
      provider_id: :get_person_ids,
      encounter_type: :get_encounter_type_ids,
      program_id: :get_program_workflow_ids,
      form_id: :get_form_ids
    }]
  }

  group4_models = {
    orders: [Order, {
      encounter_id: :get_encounter_ids,
      patient_id: :get_person_ids,
      creator: :get_new_user_ids,
      orderer: :get_new_user_ids,
      voided_by: :get_new_user_ids,
      obs_id: :get_obs_ids,
      order_type_id: :get_order_type_ids,
      concept_id: :get_concept_ids,
      discontinued_by: :get_new_user_ids,
      discontinued_reason: :get_concept_ids
    }],
    patient_state: [PatientState, {
      patient_program_id: :get_program_ids,
      creator: :get_new_user_ids,
      changed_by: :get_new_user_ids,
      voided_by: :get_new_user_ids
    }]
  }

  group5_models = {
    obs: [Observation, {
      encounter_id: :get_encounter_ids,
      order_id: :get_order_ids,
      creator: :get_new_user_ids,
      voided_by: :get_new_user_ids,
      person_id: :get_person_ids,
      # obs_group_id is handled separately by update_group_obs_ids after all obs are inserted
      concept_id: :get_concept_ids,
      value_coded: :get_concept_ids,
      value_drug: :get_drug_ids
    }],
    lims_acknowledgement_statuses: [
      LimsAcknowledgementStatus, {
        order_id: :get_order_ids,
        voided_by: :get_new_user_ids
      }
    ]
  }

  group6_models = {
    drug_order: [DrugOrder, {
      order_id: :get_order_ids,
      drug_inventory_id: :get_drug_ids
    }]
  }

  groups = [group1_models, group2_models, group3_models, group4_models, group5_models, group6_models]

  groups.each do |group|
    populate_group(group.map { |table, (model, dependencies)| [table, model, source_db, dependencies] })
  end
  update_group_obs_ids(source_db, obs_id: :get_obs_ids,
                                  encounter_id: :get_encounter_ids,
                                  order_id: :get_order_ids,
                                  creator: :get_new_user_ids,
                                  voided_by: :get_new_user_ids,
                                  person_id: :get_person_ids,
                                  obs_group_id: :get_obs_ids,
                                  concept_id: :get_concept_ids,
                                  value_coded: :get_concept_ids,
                                  value_drug: :get_drug_ids)

  # Final cleanup: Clear all active connections
  puts "\n✓ Migration complete! Cleaning up connections..."
  ActiveRecord::Base.connection_pool.disconnect!
  puts '✓ All database connections closed.'
end
