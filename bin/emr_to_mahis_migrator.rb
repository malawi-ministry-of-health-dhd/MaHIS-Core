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
# Increase pool size to handle nested queries in parallel processing
# Each thread may need multiple connections for nested lookups
pool_size = optimal_thread_count * 3 + 10 # More generous pool for nested queries
ActiveRecord::Base.establish_connection(
  database_config[Rails.env].merge(
    'pool' => pool_size,
    'reaping_frequency' => 5,          # More frequent reaping
    'checkout_timeout' => 30           # Longer timeout for complex queries
  )
)
puts "✓ Connection pool configured: #{pool_size} connections, #{optimal_thread_count} threads"
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

# HIV Program filtering caches
HIV_PATIENT_IDS = Set.new
HIV_ENCOUNTER_IDS = Set.new
HIV_PROGRAM_ID = 1 # HIV PROGRAM program_id

# Track orphaned references for data quality reporting
ORPHANED_REFERENCES = Hash.new { |h, k| h[k] = [] }

# Track performance metrics for bottleneck identification
PERFORMANCE_METRICS = {
  table_timings: {},
  group_timings: {},
  query_counts: Hash.new(0),
  memory_snapshots: [],
  start_time: Time.now
}

# Real-time performance tracking and adaptive tuning
REALTIME_MONITOR = {
  current_table: nil,
  table_start_time: nil,
  slow_threshold_seconds: 60,
  recent_batch_times: [],
  adaptive_tuning_enabled: ENV['ADAPTIVE_TUNING'] != 'false',
  auto_apply_fixes: ENV['AUTO_APPLY_FIXES'] != 'false',
  current_thread_count: nil,
  current_batch_size: nil,
  adjustments_applied: []
}

# Performance thresholds for auto-tuning
PERFORMANCE_THRESHOLDS = {
  records_per_second_min: 100,
  memory_usage_max: 85,
  cpu_usage_max: 90,
  critical_memory: 95,
  critical_cpu: 95
}

# Mutex for thread-safe cache updates
CACHE_MUTEX = Mutex.new

def prepare_centralized_db
  puts 'Preparing Centralized database for migration...'

  # Extend MySQL session timeouts on the main connection to handle large tables.
  # Per-thread connections also set these, but the main connection needs it too.
  begin
    ActiveRecord::Base.connection.execute(
      'SET SESSION net_read_timeout=3600, net_write_timeout=3600, wait_timeout=28800, interactive_timeout=28800'
    )
    puts '✓ Extended MySQL session timeouts (net_read/write=3600s, wait=28800s)'
  rescue StandardError => e
    puts "⚠ Could not set MySQL session timeouts: #{e.message}"
  end

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

# Ensure all critical indexes exist for optimal migration performance
def ensure_migration_indexes(source_db)
  target_db = ActiveRecord::Base.connection.current_database
  conn = ActiveRecord::Base.connection

  indexes = [
    # [database,   table,                          index_name,                     column]
    [source_db, 'encounter',                    'idx_enc_program_id',           'program_id'],
    [source_db, 'encounter',                    'idx_enc_voided',               'voided'],
    [source_db, 'obs',                          'idx_obs_obs_id',               'obs_id'],
    [source_db, 'obs',                          'idx_obs_voided',               'voided'],
    [source_db, 'drug_order',                   'idx_drug_order_order_id',      'order_id'],
    [source_db, 'orders',                       'idx_orders_voided',            'voided'],
    [source_db, 'lims_acknowledgement_statuses', 'idx_lims_src_order_id', 'order_id'],
    [source_db, 'patient',                      'idx_patient_patient_id',       'patient_id'],
    [source_db, 'patient',                      'idx_patient_voided',           'voided'],
    [source_db, 'person',                       'idx_person_voided',            'voided'],
    [source_db, 'patient_program',              'idx_patient_program_voided',   'voided'],
    [source_db, 'patient_state',                'idx_patient_state_voided',     'voided'],
    [source_db, 'relationship',                 'idx_relationship_voided',      'voided'],
    [source_db, 'person_name',                  'idx_person_name_voided',       'voided'],
    [source_db, 'person_address',               'idx_person_address_voided',    'voided'],
    [source_db, 'person_attribute',             'idx_person_attr_voided',       'voided'],
    [target_db, 'person',                       'idx_person_person_id',         'person_id'],
    [target_db, 'patient',                      'idx_patient_patient_id',       'patient_id'],
    [target_db, 'encounter',                    'idx_encounter_encounter_id',   'encounter_id'],
    [target_db, 'obs',                          'idx_obs_obs_id',               'obs_id'],
    [target_db, 'obs',                          'idx_obs_uuid',                 'uuid'],
    [target_db, 'orders',                       'idx_orders_uuid',              'uuid'],
    [target_db, 'drug_order',                   'idx_drug_order_order_id',      'order_id'],
    [target_db, 'lims_acknowledgement_statuses', 'idx_lims_tgt_order_id', 'order_id'],
    [target_db, 'users',                        'idx_users_user_id',            'user_id'],
    [target_db, 'users',                        'idx_users_uuid',               'uuid'],
    [source_db, 'obs',                          'idx_obs_uuid_src',             'uuid'],
    [source_db, 'orders',                       'idx_orders_uuid_src',          'uuid']
  ]

  puts "\n" + '=' * 80
  puts 'INDEX OPTIMIZATION CHECK'
  puts '=' * 80
  created = skipped = failed = 0

  indexes.each do |db, tbl, idx_name, col|
    # Skip if table doesn't exist in that DB
    tbl_exists = conn.select_value(
      "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
       WHERE TABLE_SCHEMA='#{db}' AND TABLE_NAME='#{tbl}'"
    ).to_i > 0
    next unless tbl_exists

    idx_exists = conn.select_value(
      "SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS
       WHERE TABLE_SCHEMA='#{db}' AND TABLE_NAME='#{tbl}' AND INDEX_NAME='#{idx_name}'"
    ).to_i > 0

    if idx_exists
      puts "  ⏭️  Skipped  (exists): #{db}.#{tbl}(#{col})"
      skipped += 1
    else
      begin
        print "  ⏳ Creating index: #{db}.#{tbl}(#{col}) ..."
        $stdout.flush
        start = Time.now
        conn.execute("CREATE INDEX `#{idx_name}` ON `#{db}`.`#{tbl}` (`#{col}`)")
        duration = (Time.now - start).round(1)
        puts " done (#{duration}s)"
        created += 1
      rescue StandardError => e
        puts ' FAILED'
        puts "  ⚠️  #{db}.#{tbl}(#{col}): #{e.message.split('.').first}"
        failed += 1
      end
    end
  end

  puts "  ✅ Created #{created} new index(es)" if created > 0
  puts "  ✓ #{skipped} index(es) already existed | #{failed} failed"
  puts '=' * 80
end

# Load HIV patient IDs from source database for filtering
def load_hiv_patient_ids(source_db)
  puts "\n🔍 Loading HIV program patient IDs from source..."

  # Get all patient_ids enrolled in HIV program (program_id = 1)
  result = ActiveRecord::Base.connection.execute(<<~SQL)
    SELECT DISTINCT patient_id#{' '}
    FROM #{source_db}.patient_program#{' '}
    WHERE program_id = #{HIV_PROGRAM_ID}
  SQL

  result.each do |row|
    HIV_PATIENT_IDS.add(row[0])
  end

  puts "✓ Loaded #{HIV_PATIENT_IDS.size} HIV patient IDs"
end

# Load HIV encounter IDs from source database for filtering
def load_hiv_encounter_ids(source_db)
  puts '🔍 Loading HIV encounter IDs from source...'

  # Get all encounters linked to HIV program
  result = ActiveRecord::Base.connection.execute(<<~SQL)
    SELECT DISTINCT encounter_id#{' '}
    FROM #{source_db}.encounter#{' '}
    WHERE program_id = #{HIV_PROGRAM_ID}
  SQL

  result.each do |row|
    HIV_ENCOUNTER_IDS.add(row[0])
  end

  puts "✓ Loaded #{HIV_ENCOUNTER_IDS.size} HIV encounter IDs"
end

# Check if a table should be filtered for HIV program only
def hiv_filter_required?(table_name)
  %w[patient_program patient_identifier encounter patient_state orders obs drug_order
     pharmacy_obs].include?(table_name.to_s)
end

# Build HIV filter WHERE clause for specific tables
def build_hiv_filter_clause(table_name, source_db)
  case table_name.to_s
  when 'patient_program'
    "program_id = #{HIV_PROGRAM_ID}"
  when 'patient_identifier'
    "patient_id IN (SELECT DISTINCT patient_id FROM #{source_db}.patient_program WHERE program_id = #{HIV_PROGRAM_ID})"
  when 'encounter'
    "program_id = #{HIV_PROGRAM_ID}"
  when 'patient_state'
    # patient_state references patient_program_id, so we need to get HIV patient_program IDs
    # This is trickier - we'll filter this in populate_records instead
    nil
  when 'orders', 'obs'
    "encounter_id IN (SELECT DISTINCT encounter_id FROM #{source_db}.encounter WHERE program_id = #{HIV_PROGRAM_ID})"
  when 'drug_order'
    "order_id IN (SELECT o.order_id FROM #{source_db}.orders o JOIN #{source_db}.encounter e ON e.encounter_id = o.encounter_id WHERE e.program_id = #{HIV_PROGRAM_ID})"
  end
end

# Report data quality issues found during migration
def report_data_quality_issues
  return if ORPHANED_REFERENCES.empty?

  puts "\n" + '=' * 80
  puts 'DATA QUALITY REPORT - Orphaned References Found'
  puts '=' * 80

  ORPHANED_REFERENCES.each do |table, ids|
    puts "\n⚠ #{table.to_s.upcase}: #{ids.size} orphaned reference(s)"
    puts "  Missing IDs: #{ids.sort.join(', ')}"
    puts '  → These references were mapped to admin user as fallback'
  end

  # Save detailed report to log file
  report_file = Rails.root.join('log', "data_quality_report_#{SITE_ID}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
  File.write(report_file, JSON.pretty_generate({
                                                 site_id: SITE_ID,
                                                 timestamp: Time.now.iso8601,
                                                 orphaned_references: ORPHANED_REFERENCES
                                               }))

  puts "\n✓ Detailed report saved to: #{report_file}"
  puts '=' * 80
end

# Start monitoring a table
def start_table_monitoring(table_name, record_count)
  CACHE_MUTEX.synchronize do
    REALTIME_MONITOR[:current_table] = table_name
    REALTIME_MONITOR[:table_start_time] = Time.now
    REALTIME_MONITOR[:recent_batch_times] = []
  end
  puts "\n🔍 [MONITOR] Starting #{table_name} (#{record_count} records)"
end

# Track batch performance and detect issues
def track_batch_performance(table_name, batch_size, duration)
  records_per_sec = (batch_size / duration).round(2)

  CACHE_MUTEX.synchronize do
    REALTIME_MONITOR[:recent_batch_times] << {
      timestamp: Time.now,
      duration: duration,
      records_per_sec: records_per_sec,
      batch_size: batch_size
    }
    REALTIME_MONITOR[:recent_batch_times] = REALTIME_MONITOR[:recent_batch_times].last(10)
  end

  detect_and_alert_bottlenecks(table_name, records_per_sec, duration)
  records_per_sec
end

# Detect bottlenecks in real-time and auto-apply fixes
def detect_and_alert_bottlenecks(table_name, records_per_sec, batch_duration)
  alerts = []
  actions = []

  if records_per_sec < PERFORMANCE_THRESHOLDS[:records_per_second_min]
    alerts << "⚠️  SLOW: #{records_per_sec} rec/s (threshold: #{PERFORMANCE_THRESHOLDS[:records_per_second_min]})"
  end

  if batch_duration > REALTIME_MONITOR[:slow_threshold_seconds]
    alerts << "⚠️  BATCH TIMEOUT: #{batch_duration.round(2)}s (threshold: #{REALTIME_MONITOR[:slow_threshold_seconds]}s)"
  end

  memory_stats = Sys::Memory
  memory_usage = (memory_stats.used.to_f / memory_stats.total * 100).round(2)
  cpu_usage = Sys::CPU.load_avg[0] / Parallel.processor_count * 100

  # Critical thresholds - immediate action required
  critical_situation = false
  if memory_usage > PERFORMANCE_THRESHOLDS[:critical_memory]
    alerts << "🚨 CRITICAL MEMORY: #{memory_usage}%"
    critical_situation = true
  elsif memory_usage > PERFORMANCE_THRESHOLDS[:memory_usage_max]
    alerts << "⚠️  HIGH MEMORY: #{memory_usage}% (threshold: #{PERFORMANCE_THRESHOLDS[:memory_usage_max]}%)"
  end

  if cpu_usage > PERFORMANCE_THRESHOLDS[:critical_cpu]
    alerts << "🚨 CRITICAL CPU: #{cpu_usage.round(2)}%"
    critical_situation = true
  elsif cpu_usage > PERFORMANCE_THRESHOLDS[:cpu_usage_max]
    alerts << "⚠️  HIGH CPU: #{cpu_usage.round(2)}% (threshold: #{PERFORMANCE_THRESHOLDS[:cpu_usage_max]}%)"
  end

  # Auto-apply fixes if enabled
  if alerts.any? && REALTIME_MONITOR[:auto_apply_fixes]
    if critical_situation
      puts "\n" + '=' * 80
      puts '🚨 CRITICAL PERFORMANCE ISSUE - APPLYING EMERGENCY FIXES'
      alerts.each { |alert| puts "   #{alert}" }
      actions = apply_emergency_tuning(memory_usage, cpu_usage)
    else
      puts "\n" + '=' * 80
      puts "⚠️  BOTTLENECK DETECTED in #{table_name} - Applying optimizations"
      alerts.each { |alert| puts "   #{alert}" }
      actions = apply_adaptive_tuning(records_per_sec, memory_usage, cpu_usage)
    end

    if actions.any?
      puts "\n✅ Actions applied:"
      actions.each { |action| puts "   ✓ #{action}" }

      CACHE_MUTEX.synchronize do
        REALTIME_MONITOR[:adjustments_applied] << {
          timestamp: Time.now,
          table: table_name,
          actions: actions,
          metrics: { records_per_sec: records_per_sec, memory: memory_usage, cpu: cpu_usage }
        }
      end
    end
    puts '=' * 80 + "\n"
  elsif alerts.any?
    puts "\n" + '=' * 80
    puts "🚨 BOTTLENECK DETECTED in #{table_name}"
    alerts.each { |alert| puts "   #{alert}" }

    if REALTIME_MONITOR[:adaptive_tuning_enabled]
      suggestions = generate_tuning_suggestions(records_per_sec, memory_usage, cpu_usage)
      puts "\n💡 Suggestions (set AUTO_APPLY_FIXES=true to auto-apply):"
      suggestions.each { |suggestion| puts "   → #{suggestion}" }
    end
    puts '=' * 80 + "\n"
  end
end

# Apply emergency tuning for critical situations
def apply_emergency_tuning(memory_usage, cpu_usage)
  actions = []

  # Pause processing briefly to let system recover
  sleep 2
  actions << 'Paused for 2s to allow system recovery'

  # Reduce batch size aggressively
  if REALTIME_MONITOR[:current_batch_size] && REALTIME_MONITOR[:current_batch_size] > 1000
    new_size = [REALTIME_MONITOR[:current_batch_size] / 2, 1000].max
    CACHE_MUTEX.synchronize do
      REALTIME_MONITOR[:current_batch_size] = new_size
    end
    actions << "Reduced batch size to #{new_size} (emergency)"
  end

  # Reduce threads if high CPU
  if cpu_usage > PERFORMANCE_THRESHOLDS[:critical_cpu] && REALTIME_MONITOR[:current_thread_count] && REALTIME_MONITOR[:current_thread_count] > 1
    new_threads = [REALTIME_MONITOR[:current_thread_count] / 2, 1].max
    CACHE_MUTEX.synchronize do
      REALTIME_MONITOR[:current_thread_count] = new_threads
    end
    actions << "Reduced thread count to #{new_threads} (emergency)"
  end

  # Trigger garbage collection if high memory
  if memory_usage > PERFORMANCE_THRESHOLDS[:critical_memory]
    GC.start(full_mark: true, immediate_sweep: true)
    actions << 'Triggered full garbage collection'
  end

  actions
end

# Apply adaptive tuning based on performance metrics
def apply_adaptive_tuning(records_per_sec, memory_usage, cpu_usage)
  actions = []

  # Slow processing - reduce overhead
  if (records_per_sec < 50) && REALTIME_MONITOR[:current_thread_count] && REALTIME_MONITOR[:current_thread_count] > 2
    new_threads = [REALTIME_MONITOR[:current_thread_count] - 1, 2].max
    CACHE_MUTEX.synchronize do
      REALTIME_MONITOR[:current_thread_count] = new_threads
    end
    actions << "Reduced threads to #{new_threads} (reducing overhead)"
  end

  # High memory - reduce batch size
  if (memory_usage > 85) && REALTIME_MONITOR[:current_batch_size] && REALTIME_MONITOR[:current_batch_size] > 2000
    new_size = [REALTIME_MONITOR[:current_batch_size] * 0.7, 2000].max.to_i
    CACHE_MUTEX.synchronize do
      REALTIME_MONITOR[:current_batch_size] = new_size
    end
    actions << "Reduced batch size to #{new_size} (high memory)"

    # Also trigger GC
    GC.start
    actions << 'Triggered garbage collection'
  end

  # High CPU - reduce threads
  if (cpu_usage > 90) && REALTIME_MONITOR[:current_thread_count] && REALTIME_MONITOR[:current_thread_count] > 2
    new_threads = [REALTIME_MONITOR[:current_thread_count] - 1, 2].max
    CACHE_MUTEX.synchronize do
      REALTIME_MONITOR[:current_thread_count] = new_threads
    end
    actions << "Reduced threads to #{new_threads} (high CPU)"
  end

  # Good performance with headroom - increase capacity
  if records_per_sec > 200 && memory_usage < 60 && cpu_usage < 60 && REALTIME_MONITOR[:current_batch_size] && REALTIME_MONITOR[:current_batch_size] < 50_000
    new_size = [REALTIME_MONITOR[:current_batch_size] * 1.3, 50_000].min.to_i
    CACHE_MUTEX.synchronize do
      REALTIME_MONITOR[:current_batch_size] = new_size
    end
    actions << "Increased batch size to #{new_size} (system has headroom)"
  end

  actions
end

# Generate tuning suggestions based on current metrics
def generate_tuning_suggestions(records_per_sec, memory_usage, cpu_usage)
  suggestions = []

  if records_per_sec < 50
    suggestions << 'Consider reducing parallel threads (high overhead suspected)'
    suggestions << 'Check for slow foreign key lookups - review cache hit rates'
    suggestions << 'Verify database indexes on join columns'
  end

  if memory_usage > 85
    suggestions << 'Reduce batch size to lower memory footprint'
    suggestions << 'Consider processing fewer tables in parallel'
  end

  if cpu_usage > 90
    suggestions << 'Reduce thread count to prevent CPU thrashing'
    suggestions << 'Check if too many parallel operations are competing'
  end

  if records_per_sec > 100 && memory_usage < 60 && cpu_usage < 70
    suggestions << 'System has headroom - could increase batch size or threads'
  end

  suggestions
end

# End table monitoring and report
def end_table_monitoring(table_name, total_records)
  return unless REALTIME_MONITOR[:table_start_time]

  duration = Time.now - REALTIME_MONITOR[:table_start_time]
  avg_speed = total_records > 0 ? (total_records / duration).round(2) : 0

  puts "✅ [MONITOR] Completed #{table_name}: #{format_duration(duration)} @ #{avg_speed} rec/s"
end

# Helper to format duration in human-readable format
def format_duration(seconds)
  return "#{seconds.round(2)}s" if seconds < 60

  minutes = (seconds / 60).floor
  remaining_seconds = (seconds % 60).round(2)

  return "#{minutes}m #{remaining_seconds}s" if minutes < 60

  hours = (minutes / 60).floor
  remaining_minutes = minutes % 60

  "#{hours}h #{remaining_minutes}m #{remaining_seconds.round(0)}s"
end

# Capture memory snapshot for performance tracking
def capture_memory_snapshot(label)
  memory_stats = Sys::Memory
  used_memory_gb = (memory_stats.used.to_f / (1024**3)).round(2)
  free_memory_gb = ((memory_stats.total - memory_stats.used).to_f / (1024**3)).round(2)

  CACHE_MUTEX.synchronize do
    PERFORMANCE_METRICS[:memory_snapshots] << {
      timestamp: Time.now.iso8601,
      label: label,
      used_gb: used_memory_gb,
      free_gb: free_memory_gb,
      total_gb: (memory_stats.total.to_f / (1024**3)).round(2)
    }
  end
end

# Report performance metrics and identify bottlenecks
def report_performance_metrics
  total_duration = Time.now - PERFORMANCE_METRICS[:start_time]

  puts "\n" + '=' * 80
  puts 'PERFORMANCE REPORT - Migration Bottleneck Analysis'
  puts '=' * 80
  puts "\n📊 Overall Statistics:"
  puts "  Total Duration: #{format_duration(total_duration)}"
  puts "  Total Memory Snapshots: #{PERFORMANCE_METRICS[:memory_snapshots].size}"

  if PERFORMANCE_METRICS[:group_timings].any?
    puts "\n⏱️  Group Processing Times:"
    PERFORMANCE_METRICS[:group_timings].sort_by { |_, v| -v }.each_with_index do |(group, duration), idx|
      percentage = (duration / total_duration * 100).round(2)
      puts "  #{idx + 1}. #{group}: #{format_duration(duration)} (#{percentage}%)"
    end
  end

  if PERFORMANCE_METRICS[:table_timings].any?
    puts "\n🐌 Slowest Tables (Top 10):"
    PERFORMANCE_METRICS[:table_timings].sort_by do |_, v|
      -v[:duration]
    end.first(10).each_with_index do |(table, metrics), idx|
      percentage = (metrics[:duration] / total_duration * 100).round(2)
      records_per_sec = metrics[:records] > 0 ? (metrics[:records] / metrics[:duration]).round(2) : 0
      puts "  #{idx + 1}. #{table}:"
      puts "      Duration: #{format_duration(metrics[:duration])} (#{percentage}%)"
      puts "      Records: #{metrics[:records]}"
      puts "      Speed: #{records_per_sec} records/sec"
    end
  end

  if PERFORMANCE_METRICS[:memory_snapshots].any?
    memory_stats = PERFORMANCE_METRICS[:memory_snapshots]
    max_memory = memory_stats.map { |s| s[:used_gb] }.max
    avg_memory = (memory_stats.map { |s| s[:used_gb] }.sum / memory_stats.size).round(2)

    puts "\n💾 Memory Usage:"
    puts "  Peak Memory: #{max_memory} GB"
    puts "  Average Memory: #{avg_memory} GB"
    puts "  Snapshots Taken: #{memory_stats.size}"
  end

  report_file = Rails.root.join('log', "performance_report_#{SITE_ID}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
  File.write(report_file, JSON.pretty_generate({
                                                 site_id: SITE_ID,
                                                 total_duration_seconds: total_duration.round(2),
                                                 started_at: PERFORMANCE_METRICS[:start_time].iso8601,
                                                 completed_at: Time.now.iso8601,
                                                 group_timings: PERFORMANCE_METRICS[:group_timings].transform_values do |v|
                                                   v.round(2)
                                                 end,
                                                 table_timings: PERFORMANCE_METRICS[:table_timings].transform_values do |v|
                                                   {
                                                     duration_seconds: v[:duration].round(2),
                                                     records: v[:records],
                                                     records_per_second: v[:records] > 0 ? (v[:records] / v[:duration]).round(2) : 0
                                                   }
                                                 end,
                                                 memory_snapshots: PERFORMANCE_METRICS[:memory_snapshots]
                                               }))

  puts "\n✓ Detailed performance report saved to: #{report_file}"
  puts '=' * 80
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
  max_threads = (num_cores * 0.8).to_i

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

# Constant batch size used across all tables.
# Override with BATCH_SIZE env var, e.g. BATCH_SIZE=20000.
DEFAULT_BATCH_SIZE = (ENV['BATCH_SIZE'] || 20_000).to_i

# Process in Batches with Dynamic Threads and Percentage Tracking
def process_in_batches(source_db, table_name, batch_size = nil, target_model = nil)
  # Convert table_name to string
  table_name_str = table_name.to_s

  batch_size ||= DEFAULT_BATCH_SIZE
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

  # Build HIV filter for counting records
  hiv_filter = build_hiv_filter_clause(table_name_str, source_db) if hiv_filter_required?(table_name_str)
  count_where = hiv_filter ? " WHERE #{hiv_filter}" : ''

  processed_records = 0
  total_records = if test_limit
                    [ActiveRecord::Base.connection.select_one("SELECT COUNT(*) AS count
                                                            FROM #{source_db}.#{table_name_str}#{count_where}")['count'].to_i, test_limit].min
                  else
                    ActiveRecord::Base.connection.select_one("SELECT COUNT(*) AS count
                                                            FROM #{source_db}.#{table_name_str}#{count_where}")['count'].to_i
                  end

  puts "🧪 TEST MODE: Limiting to #{test_limit} records per table" if test_limit
  puts "🔍 HIV FILTER: Processing #{total_records} HIV-related records from #{table_name_str}" if hiv_filter
  num_threads = test_limit ? 1 : optimal_threads
  puts "Using #{num_threads} threads for processing #{table_name_str}..."

  start_table_monitoring(table_name_str, total_records)

  Parallel.each(batch_ranges, in_threads: num_threads) do |batch_range|
    batch_start_time = Time.now
    retry_count = 0
    max_retries = 3

    begin
      # Use connection pool to manage connections properly in threads
      ActiveRecord::Base.connection_pool.with_connection do
        # Extend MySQL session timeouts to prevent disconnection on large/slow batches.
        # net_read_timeout: max seconds to wait for data from server (default 30s — too short for 11M obs)
        # wait_timeout: max idle seconds before server closes the connection
        begin
          ActiveRecord::Base.connection.execute(
            'SET SESSION net_read_timeout=3600, net_write_timeout=3600, wait_timeout=28800, interactive_timeout=28800'
          )
        rescue StandardError
          nil # Non-fatal: worst case the default (short) timeout still applies
        end

        # Reuse the HIV filter built earlier

        records = if test_limit
                    # In test mode, just get first N records without ID range filtering
                    where_clause = hiv_filter
                    query_with_columns("#{source_db}.#{table_name_str}", where_clause, test_limit, nil, target_model)
                  elsif %w[global_property user_role user_property].include?(table_name_str)
                    where_clause = table_name_str == 'global_property' ? "property = 'site_prefix'" : nil
                    query_with_columns("#{source_db}.#{table_name_str}", where_clause, nil, nil, target_model)
                  else
                    full_table_name = "#{source_db}.#{table_name_str}"
                    column_name = ActiveRecord::Base.connection.columns(full_table_name).first.name

                    # Combine batch range with HIV filter
                    where_parts = ["#{column_name} >= #{batch_range.first} AND #{column_name} <= #{batch_range.last}"]
                    where_parts << hiv_filter if hiv_filter
                    where_clause = where_parts.join(' AND ')

                    query_with_columns(full_table_name, where_clause, nil, nil, target_model)
                  end

        next if records.blank?

        yield(records)

        batch_duration = Time.now - batch_start_time
        records_per_sec = track_batch_performance(table_name_str, records.size, batch_duration)

        processed_records += records.size
        percentage = ((processed_records.to_f / total_records) * 100).round(2)
        puts "Processing #{table_name_str}: #{percentage}% (#{processed_records}/#{total_records}) @ #{records_per_sec} rec/s"
      end
    rescue Mysql2::Error::ConnectionError, Mysql2::Error, ActiveRecord::StatementInvalid => e
      conn_error = e.message.match?(/Lost connection|gone away|hostname|connecting with/i)
      if conn_error && retry_count < max_retries
        retry_count += 1
        wait = retry_count * 5
        puts "⚠️  Connection error on #{table_name_str} [#{batch_range.first}-#{batch_range.last}]," \
             " retry #{retry_count}/#{max_retries} in #{wait}s: #{e.message.lines.first.strip}"
        begin
          ActiveRecord::Base.connection_pool.release_connection
        rescue StandardError
          nil
        end
        sleep(wait)
        retry
      else
        puts "❌ Batch failed (#{table_name_str} #{batch_range.first}-#{batch_range.last}):" \
             " #{e.message.lines.first.strip}"
      end
    end
  end

  end_table_monitoring(table_name_str, processed_records)
ensure
  # Clear any lingering connections after all parallel processing completes
  ActiveRecord::Base.connection_pool.release_connection if ActiveRecord::Base.connection_pool.active_connection?
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
  Time.now

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
                  when 'UserProgram'
                    records.map { |r| [r[:user_id], r[:program_id]] }
                  when 'DrugIngredient'
                    records.map { |r| [r[:concept_id], r[:ingredient_id]] }
                  when 'PharmacyStockBalance', 'PharmacyStockVerification', 'Pharmacies'
                    # These tables skip duplicate checking - always insert
                    []
                  when 'Pharmacy'
                    records.map { |r| r[:pharmacy_module_id] }
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
                    when 'UserProgram'
                      target_model.unscoped.where(user_id: record_keys.map(&:first), program_id: record_keys.map(&:last))
                                  .pluck(:user_id, :program_id).map do |u, p|
                        [u, p]
                      end.to_set
                    when 'DrugIngredient'
                      target_model.unscoped.where(concept_id: record_keys.map(&:first), ingredient_id: record_keys.map(&:last))
                                  .pluck(:concept_id, :ingredient_id).map do |c, i|
                        [c, i]
                      end.to_set
                    when 'PharmacyStockBalance', 'PharmacyStockVerification', 'Pharmacies'
                      Set.new
                    when 'Pharmacy'
                      target_model.unscoped.where(pharmacy_module_id: record_keys).pluck(:pharmacy_module_id).to_set
                    else
                      target_model.unscoped.where(uuid: record_keys).pluck(:uuid).to_set
                    end

    # HIV Program Filtering PRE-PASS: Remove non-HIV PatientState records BEFORE FK remapping.
    # PatientState has patient_program_id as a FK. Non-HIV patient_programs are never migrated
    # to the target DB, so their patient_program_ids would not be found during FK mapping.
    # We must filter using source patient_program_ids (still unmapped at this point).
    if target_model.to_s == 'PatientState' && records.any? && records.first.key?(:patient_program_id)
      source_pp_ids = records.map { |r| r[:patient_program_id] }.compact.uniq
      if source_pp_ids.any?
        hiv_pp_ids = ActiveRecord::Base.connection.select_values(<<~SQL)
          SELECT patient_program_id
          FROM #{source_db}.patient_program
          WHERE patient_program_id IN (#{source_pp_ids.join(',')})
          AND program_id = #{HIV_PROGRAM_ID}
        SQL
        hiv_pp_ids_set = Set.new(hiv_pp_ids)
        records.reject! { |r| !hiv_pp_ids_set.include?(r[:patient_program_id]) }
      end
    end

    # HIV Program Filtering PRE-PASS: Remove non-HIV LimsAcknowledgementStatus records BEFORE FK remapping.
    # lims_acknowledgement_statuses has no SQL-level HIV filter, so we filter here using source order_ids
    # (before they are remapped to destination IDs by get_order_ids).
    if target_model.to_s == 'LimsAcknowledgementStatus' && records.any? && records.first.key?(:order_id)
      source_lims_order_ids = records.map { |r| r[:order_id] }.compact.uniq
      if source_lims_order_ids.any?
        hiv_lims_order_ids = ActiveRecord::Base.connection.select_values(<<~SQL)
          SELECT o.order_id
          FROM #{source_db}.orders o
          JOIN #{source_db}.encounter e ON e.encounter_id = o.encounter_id
          WHERE o.order_id IN (#{source_lims_order_ids.join(',')})
          AND e.program_id = #{HIV_PROGRAM_ID}
        SQL
        hiv_lims_order_ids_set = Set.new(hiv_lims_order_ids)
        records.reject! { |r| !hiv_lims_order_ids_set.include?(r[:order_id]) }
      end
    end

    # Update foreign key mappings
    # Skip obs_group_id for Observations - will be updated in separate batch later
    # Skip obs_id for Orders - obs don't exist yet, will be backfilled after obs migration
    keys_to_process = if target_model.to_s == 'Observation'
                        foreign_keys.reject { |key, _| key == :obs_group_id }
                      elsif target_model.to_s == 'Order'
                        foreign_keys.reject { |key, _| key == :obs_id }
                      else
                        foreign_keys
                      end

    keys_to_process.each do |foreign_key, mapping_method|
      records = send(mapping_method, records, foreign_key, source_db)
    end

    # HIV Program Filtering: Filter pharmacy_obs records not related to HIV program.
    # DrugOrder: already filtered at SQL level via build_hiv_filter_clause — no post-FK filter needed.
    # LimsAcknowledgementStatus: filtered in the PRE-PASS above, before FK remapping.
    # Both were removed from this post-FK filter because order_ids are remapped to destination IDs
    # at this point, making source DB lookups incorrect (causing ~47% of valid records to be dropped).
    if target_model.to_s == 'Pharmacy'
      # Keep only pharmacy_obs records linked to HIV observations
      if HIV_ENCOUNTER_IDS.empty?
        puts '⚠️  WARNING: HIV_ENCOUNTER_IDS is empty for Pharmacy filtering. Skipping all records.'
        records.clear
      elsif records.any? && records.first.key?(:dispensation_obs_id)
        source_obs_ids = records.map { |r| r[:dispensation_obs_id] }.compact.uniq
        if source_obs_ids.any?
          hiv_obs_ids = ActiveRecord::Base.connection.select_values(<<~SQL)
            SELECT obs_id#{' '}
            FROM #{source_db}.obs#{' '}
            WHERE obs_id IN (#{source_obs_ids.join(',')})#{' '}
            AND encounter_id IN (#{HIV_ENCOUNTER_IDS.to_a.join(',')})
          SQL
          hiv_obs_ids_set = Set.new(hiv_obs_ids)
          records.reject! { |r| !hiv_obs_ids_set.include?(r[:dispensation_obs_id]) }
        end
      end
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
      when 'UserProgram'
        existing_keys.include?([record[:user_id], record[:program_id]])
      when 'DrugIngredient'
        existing_keys.include?([record[:concept_id], record[:ingredient_id]])
      when 'PharmacyStockBalance', 'PharmacyStockVerification', 'Pharmacies'
        false # Never reject - always insert
      when 'Pharmacy'
        existing_keys.include?(record[:pharmacy_module_id])
      else
        existing_keys.include?(record[:uuid])
      end
    end

    next if insertable_records.blank?

    # Set location_id for tables that have this column
    if %w[PharmacyBatch PatientIdentifier PatientProgram Encounter
          Observation].include?(target_model.to_s)
      insertable_records.each do |record|
        record[:location_id] = SITE_ID if record.key?(:location_id)
      end
    end

    # Force-set location_id for GlobalProperty (source table may not have this column)
    if target_model.to_s == 'GlobalProperty'
      insertable_records.each do |record|
        record[:location_id] = SITE_ID.to_s
      end
    end

    # For Observations, temporarily set obs_group_id to NULL - will be updated by update_group_obs_ids
    if target_model.to_s == 'Observation'
      insertable_records.each do |record|
        record[:obs_group_id] = nil if record.key?(:obs_group_id)
      end
    end

    # For Orders, temporarily set obs_id to NULL - will be backfilled by backfill_orders_obs_ids after obs migration
    if target_model.to_s == 'Order'
      insertable_records.each do |record|
        record[:obs_id] = nil if record.key?(:obs_id)
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
  unless admin_user
    puts '✗ Error: Admin user (user_id = 1) not found in source database'
    return
  end

  if User.unscoped.exists?(uuid: admin_user['uuid'])
    admin_user = User.unscoped.find_by(uuid: admin_user['uuid'])
  else
    next_user_id = User.unscoped.maximum(:user_id) + 1
    admin_user['user_id'] = next_user_id
    admin_user['creator'] = next_user_id
    admin_user['changed_by'] = next_user_id
    admin_user['person_id'] = create_user_person(admin_user.symbolize_keys, source_db)
    admin_user['location_id'] = SITE_ID

    # Check for duplicate username and append site code if needed
    if admin_user['username'].present?
      existing_user = User.unscoped.find_by(username: admin_user['username'])
      if existing_user && existing_user.uuid != admin_user['uuid']
        admin_user['username'] = "#{admin_user['username']}_#{SITE_ID}"
      end
    end

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

      # Check for duplicate username and append site code if needed
      if user[:username].present?
        existing_user = User.unscoped.find_by(username: user[:username])
        user[:username] = "#{user[:username]}_#{SITE_ID}" if existing_user && existing_user.uuid != user[:uuid]
      end

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

  user_record = query_with_columns("#{source_db}.users", "user_id = #{old_user_id}").first
  unless user_record
    # Log orphaned user reference for data quality reporting
    CACHE_MUTEX.synchronize do
      ORPHANED_REFERENCES[:users] << old_user_id unless ORPHANED_REFERENCES[:users].include?(old_user_id)
    end
    return nil
  end

  user_uuid = user_record['uuid']
  User.unscoped.find_by(uuid: user_uuid)&.id
end

def create_user_person(user, source_db)
  person_data = query_with_columns("#{source_db}.person", "person_id = #{user[:person_id]}").first
  unless person_data
    # Log orphaned person reference for data quality reporting
    CACHE_MUTEX.synchronize do
      ORPHANED_REFERENCES[:person] << user[:person_id] unless ORPHANED_REFERENCES[:person].include?(user[:person_id])
    end
    return nil
  end

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

def get_relationship_type_ids(records, key, source_db)
  fetch_new_ids_by_name(records, source_db, 'relationship_type', :relationship_type_id, :a_is_to_b, RelationshipType,
                        key)
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

# Align uuid column collation across source and target tables to allow index usage in JOINs.
# Checks each table's current collation and alters only if they differ.
def align_uuid_collations(source_db, tables)
  conn = ActiveRecord::Base.connection
  target_db = conn.current_database

  tables.each do |table|
    rows = conn.select_all(<<~SQL)
      SELECT TABLE_SCHEMA, COLLATION_NAME
      FROM information_schema.COLUMNS
      WHERE TABLE_NAME = '#{table}'
        AND COLUMN_NAME = 'uuid'
        AND TABLE_SCHEMA IN ('#{source_db}', '#{target_db}')
    SQL

    collations = rows.each_with_object({}) { |r, h| h[r['TABLE_SCHEMA']] = r['COLLATION_NAME'] }
    src_col = collations[source_db]
    tgt_col = collations[target_db]

    next unless src_col && tgt_col
    next if src_col == tgt_col

    puts "  ⚠ uuid collation mismatch on #{table}: #{source_db}=#{src_col}, #{target_db}=#{tgt_col}"
    puts "    Altering #{target_db}.#{table}.uuid to #{src_col}..."
    conn.execute("ALTER TABLE #{table} MODIFY uuid char(38) CHARACTER SET utf8mb3 COLLATE #{src_col}")
    puts "    ✓ #{target_db}.#{table}.uuid now #{src_col}"
  end
end

# Backfill orders.obs_id after obs migration (Group_5) is complete
def backfill_orders_obs_ids(source_db)
  puts "\n🔄 Backfilling orders.obs_id after obs migration..."

  total = ActiveRecord::Base.connection.select_value(
    "SELECT COUNT(*) FROM #{source_db}.orders WHERE obs_id IS NOT NULL"
  ).to_i

  if total.zero?
    puts '✓ No orders.obs_id records to backfill'
    return
  end

  puts "  Found #{total} orders records with obs_id to backfill"

  align_uuid_collations(source_db, %w[orders obs])

  ActiveRecord::Base.connection.execute(<<~SQL)
    UPDATE orders o
    JOIN #{source_db}.orders src ON o.uuid = src.uuid
    JOIN obs tgt ON tgt.uuid = (
      SELECT uuid FROM #{source_db}.obs WHERE obs_id = src.obs_id LIMIT 1
    )
    SET o.obs_id = tgt.obs_id
    WHERE src.obs_id IS NOT NULL
      AND o.obs_id IS NULL
  SQL

  updated = ActiveRecord::Base.connection.select_value(
    'SELECT COUNT(*) FROM orders WHERE obs_id IS NOT NULL'
  ).to_i

  puts "✓ orders.obs_id backfill complete (#{updated} records updated)"
end

def update_group_obs_ids(source_db, _foreign_keys = {})
  puts 'Starting obs_group_id update...'

  total_records = ActiveRecord::Base.connection
                                    .select_one("SELECT COUNT(*) AS count
                                    FROM #{source_db}.obs WHERE obs_group_id IS NOT NULL")['count'].to_i

  return if total_records == 0

  puts "Found #{total_records} observations with obs_group_id to update"
  puts 'Resolving obs_group_id via single SQL JOIN (UUID-based, no Ruby batching)...'

  # Both child obs and parent obs are already migrated into the target DB.
  # We resolve obs_group_id entirely in SQL:
  #   1. Match each target obs to its source row by UUID.
  #   2. From the source row, get the source obs_group_id.
  #   3. Look up that source obs_group_id's UUID in the source DB.
  #   4. Find the corresponding target obs by that UUID to get the new obs_id.
  align_uuid_collations(source_db, %w[obs])
  ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 0')
  ActiveRecord::Base.connection.execute(<<~SQL)
    UPDATE obs o
    JOIN #{source_db}.obs src
      ON o.uuid = src.uuid
    JOIN #{source_db}.obs src_parent
      ON src_parent.obs_id = src.obs_group_id
    JOIN obs tgt_parent
      ON tgt_parent.uuid = src_parent.uuid
    SET o.obs_group_id = tgt_parent.obs_id
    WHERE src.obs_group_id IS NOT NULL
      AND o.obs_group_id IS NULL
  SQL
  ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 1')

  updated = ActiveRecord::Base.connection.select_value(
    'SELECT COUNT(*) FROM obs WHERE obs_group_id IS NOT NULL'
  ).to_i

  puts "✓ obs_group_id update complete (#{updated} records now have obs_group_id set)"
end

# Main Execution
prepare_centralized_db
ensure_migration_indexes(source_db)
populate_users(source_db)

# Load HIV program IDs for filtering clinical data
puts "\n" + '=' * 80
puts 'HIV PROGRAM FILTERING ENABLED'
puts '=' * 80
puts '📋 Migration Scope:'
puts '   ✓ ALL person and patient records will be migrated'
puts '   ✓ ONLY HIV program clinical data will be migrated'
puts '=' * 80 + "\n"

load_hiv_patient_ids(source_db)
load_hiv_encounter_ids(source_db)

# Clear caches that are no longer needed after a group completes to free memory.
# Caches are cumulative — without clearing, they balloon across all groups.
def clear_migrated_caches(completed_group_name)
  case completed_group_name
  when 'Group_4'
    # orders + patient_state done; order and program ID mappings no longer needed
    # Keep ENCOUNTER, PERSON, USER caches — still needed by obs/drug_order
    CACHE_MUTEX.synchronize do
      ORDER_ID_CACHE.clear
      PROGRAM_ID_CACHE.clear
    end
    puts "🧹 Cleared ORDER_ID_CACHE and PROGRAM_ID_CACHE after #{completed_group_name}"
  when 'Group_5'
    # obs done; obs IDs still needed for backfill and update_group_obs_ids — keep OBS_ID_CACHE
    # Encounter IDs no longer needed for SQL filtering after obs and orders are done
    CACHE_MUTEX.synchronize do
      ENCOUNTER_ID_CACHE.clear
    end
    puts "🧹 Cleared ENCOUNTER_ID_CACHE after #{completed_group_name}"
  when 'Group_6'
    # All clinical tables done — clear everything
    CACHE_MUTEX.synchronize do
      USER_ID_CACHE.clear
      PERSON_ID_CACHE.clear
      OBS_ID_CACHE.clear
    end
    puts "🧹 Cleared remaining caches after #{completed_group_name}"
  end
  GC.start(full_mark: true, immediate_sweep: true)
end

def populate_group(group, group_name, source_db)
  start_time = Time.now
  capture_memory_snapshot("Before #{group_name}")

  tasks = group.map { |table, (model, dependencies)| [table, model, source_db, dependencies] }

  Parallel.each(tasks, in_threads: optimal_threads) do |(table, model, src_db, dependencies)|
    ActiveRecord::Base.connection_pool.with_connection do
      populate_records(table, model, src_db, dependencies)
    end
  rescue StandardError => e
    puts "❌ Error processing #{table}: #{e.message}"
    puts e.backtrace.first(10).join("\n")
  end

  duration = Time.now - start_time
  capture_memory_snapshot("After #{group_name}")

  CACHE_MUTEX.synchronize do
    PERFORMANCE_METRICS[:group_timings][group_name] = duration
  end
ensure
  # Release connections but don't disconnect the pool between groups
  ActiveRecord::Base.connection_pool.release_connection if ActiveRecord::Base.connection_pool.active_connection?
end

if __FILE__ == $0
  group1_models = {
    user_role: [UserRole, {
      user_id: :get_new_user_ids
    }],
    user_property: [UserProperty, {
      user_id: :get_new_user_ids
    }],
    user_programs: [UserProgram, {
      user_id: :get_new_user_ids,
      program_id: :get_program_workflow_ids
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
      person_b: :get_person_ids,
      relationship: :get_relationship_type_ids
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
      obs_id: :get_obs_ids, # deferred - obs_id set to nil, backfilled after Group_5
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

  groups = [
    [group1_models, 'Group_1'],
    [group2_models, 'Group_2'],
    [group3_models, 'Group_3'],
    [group4_models, 'Group_4'],
    [group5_models, 'Group_5'],
    [group6_models, 'Group_6']
  ]

  groups.each do |group, group_name|
    populate_group(group, group_name, source_db)
    clear_migrated_caches(group_name)
  end

  # Backfill orders.obs_id now that obs have been migrated in Group_5
  backfill_orders_obs_ids(source_db)

  update_group_obs_ids(source_db)

  # Report data quality issues
  report_data_quality_issues

  # Report performance metrics
  report_performance_metrics

  # Final cleanup: Clear all active connections
  puts "\n✓ Migration complete! Cleaning up connections..."
  ActiveRecord::Base.connection_pool.disconnect!
  puts '✓ All database connections closed.'
end
