# lib/tasks/change_facility_codes.rake
# rails change_facility_codes:update
namespace :change_facility_codes do
  desc 'Update multiple facility codes across multiple tables'
  task update: :environment do
    # Define the mapping of old facility codes to new facility codes
    facility_code_mapping = {
      "NK100562" => "MC010564",
      "BT240998" => "SA091908",
      "NT081005" => "MC011909",
      "ZA231702" => "SA091910",
    }

    # List of tables to update
    tables_to_update = [
      'users', 
      'stages', 
      'pharmacy_batches',
      'visits', 
      'immunization_cache_data',
      'obs', 
      'encounter'
    ]

    # Track overall success and counters
    overall_success = true
    counters = {}

    # Start timing the process
    start_time = Time.now

    puts "\n===== Facility Code Update Process ====="
    puts "Started at: #{start_time.strftime('%Y-%m-%d %H:%M:%S')}"
    puts "Processing #{facility_code_mapping.size} facility code mappings"

    # Start a database transaction to ensure atomicity
    ActiveRecord::Base.transaction do
      tables_to_update.each do |table_name|
        counters[table_name.to_sym] ||= { updated: 0, skipped: 0 }

        puts "\n--- Updating #{table_name} ---"

        facility_code_mapping.each do |old_facility_code, new_facility_code|
          # Construct the update query
          update_query = "UPDATE #{table_name} SET location_id = ? WHERE location_id = ?"

          begin
            # Execute the update query
            updated_count = ActiveRecord::Base.connection.execute(
              ActiveRecord::Base.sanitize_sql_array([update_query, new_facility_code, old_facility_code])
            )

            # Track the number of rows affected
            rows_affected = ActiveRecord::Base.connection.raw_connection.affected_rows
            counters[table_name.to_sym][:updated] += rows_affected
            print "."
          rescue StandardError => e
            # Log the error and mark the process as failed
            puts "\nError updating #{table_name} (from #{old_facility_code} to #{new_facility_code}): #{e.message}"
            counters[table_name.to_sym][:skipped] += 1
            overall_success = false

            # Raise an exception to trigger rollback
            raise ActiveRecord::Rollback, "Failed to update #{table_name}"
          end
        end
      end
    end

    # If the transaction was successful, commit the changes
    if overall_success
      puts "\n\n===== Update Complete ====="
      puts "All updates were successful!"
    else
      puts "\n\n===== Update Partially Failed ====="
      puts "Some updates were skipped due to errors."
    end

    # Calculate durations and print summary
    end_time = Time.now
    total_duration = end_time - start_time

    puts "\n--- Performance Summary ---"
    puts "Total Runtime: #{total_duration.round(2)} seconds"

    # Print update statistics for each table
    puts "\n--- Update Statistics ---"
    counters.each do |table, counts|
      if counts[:skipped] > 0
        puts "#{table}: Updated #{counts[:updated]} records, Skipped #{counts[:skipped]} records"
      else
        puts "#{table}: Updated #{counts[:updated]} records"
      end
    end

    # Memory usage (if possible)
    if defined?(Process)
      memory_usage = `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
      puts "\n--- System Resources ---"
      puts "Memory Usage: #{memory_usage.round(2)} MB"
    end
  end
end