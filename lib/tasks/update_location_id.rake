# lib/tasks/update_location_id.rake
# rails users:update_location_id
namespace :users do
  desc 'Update location IDs across multiple tables based on a predefined mapping'
  task update_location_id: :environment do

    def bulk_location_update(tables_to_update, map_facility, counters)
      # Track overall success
      overall_success = true
    
      # Start a database transaction that will cover all updates
      ActiveRecord::Base.transaction do
        database_name = ActiveRecord::Base.connection.current_database
      
        tables_to_update.each do |table_name|
          counters[table_name.to_sym] ||= { updated: 0, skipped: 0 }
      
          puts "\n--- Updating #{table_name} ---"
      
          # Use dynamically retrieved database name
          base_update_query = "UPDATE `#{database_name}`.`#{table_name}` SET location_id = ?"
      
          map_facility.each do |old_location_id, new_facility_code|
            update_query = "#{base_update_query} WHERE location_id = ?"
      
            begin
              updated_count = ActiveRecord::Base.connection.execute(
                ActiveRecord::Base.sanitize_sql_array([update_query, new_facility_code, old_location_id])
              )
      
              rows_affected = ActiveRecord::Base.connection.raw_connection.affected_rows
      
              counters[table_name.to_sym][:updated] += rows_affected
              print "."
            rescue StandardError => e
              # Log the error and mark overall process as failed
              puts "\nError updating #{table_name}: #{e.message}"
              counters[table_name.to_sym][:skipped] += 1
              
              # Raise an exception to trigger rollback
              raise ActiveRecord::Rollback, "Failed to update #{table_name}"
            end
          end
        end
    
        # If we've made it this far without raising an exception, commit the transaction
        # If any error occurred, this block will be skipped and the transaction rolled back
      end
    
      counters
    rescue => e
      # Catch any unexpected errors
      puts "Unexpected error in bulk update: #{e.message}"
      
      # Return an empty or error-indicating counter
      tables_to_update.each_with_object({}) do |table_name, error_counters|
        error_counters[table_name.to_sym] = { updated: 0, skipped: 0, error: e.message }
      end
    end

    # Start timing the entire process
    start_time = Time.now

    # Mapping of location IDs to new facility codes
    map_facility = {
      582  => "NT121225", 583  => "NT121225", 584  => "NT121225", 6    => "LL040007",
      100  => "MC010259", 1007 => "MG200808", 1018 => "MG200218", 1021 => "CR260018",
      1049 => "KU070588", 1060 => "BT240028", 1096 => "BT241813", 11   => "BK170053",
      1116 => "MC010618", 1119 => "NT081005", 1120 => "MC010098", 1121 => "NT120186",
      1132 => "MC010407", 1133 => "MC010898", 12   => "BK170053", 126  => "LL040298",
      139  => "DE030334", 140  => "DE030334", 20   => "NT120080", 203  => "MC010494",
      222  => "NT120534", 230  => "MC010551", 237  => "NK100562", 238  => "MG201537",
      239  => "NK100562", 24   => "BT241814", 248  => "NT120581", 26   => "BT241814",
      269  => "MC010618", 278  => "MG200636", 279  => "MC010637", 294  => "LL040122",
      307  => "MC010711", 347  => "LL040805", 359  => "MG200829", 36   => "NT120123",
      398  => "MC010898", 399  => "MC010898", 4    => "SA091309", 401  => "MC010898",
      402  => "SA090899", 410  => "MC010925", 420  => "MC010947", 454  => "DA021013",
      499  => "MZ161098", 5    => "LL040012", 516  => "MC011131", 567  => "MC011206",
      679  => "NT121219", 614  => "BT241293", 579  => "NT121219", 621  => "SA091312",
      622  => "SA091312", 658  => "MC011397", 696  => "LL040529", 712  => "LL040996",
      717  => "MZ160760", 75   => "LL040214", 8    => "LL040033", 851  => "LL040010",
      857  => "LL040016", 868  => "LL040316", 874  => "MC011376", 875  => "MC010441",
      877  => "MC011131", 905  => "CK270069", 914  => "TH310026", 968  => "BK170054",
      984  => "ZA230235", 844  => "LL040434", 1023 => "SA090139", 1024 => "SA090592",
      1025 => "SA091253", 1027 => "SA090660", 1102 => "ZA231702", 1118 => "MC010232",
      113  => "SA090280", 98   => "SA090255", 95   => "MC010251", 89   => "SA090240",
      661  => "SA091404", 628  => "SA091541", 624  => "SA091312", 586  => "NT081226",
      581  => "NT121225", 543  => "SA091176", 487  => "MW281081", 445  => "BT240998",
      344  => "SA090792", 337  => "NE290776", 336  => "SA090778", 335  => "SA090773",
      288  => "SA090663", 272  => "SA090626", 271  => "KU070625", 234  => "SA090559",
      185  => "MC011376", 13   => "BK170053", 1135 => "SA091699", 114  => "LL040282",
      257  => "MG200594", 890  => "LL040023", 1136 => "MC011635", 721  => "MC011635",
      1137 => "SA091286",
    }

    # Dynamically initialized counters
    counters = {}

    puts "\n===== Location ID Update Process ====="
    puts "Started at: #{start_time.strftime('%Y-%m-%d %H:%M:%S')}"
    puts "Total location mappings to process: #{map_facility.size}"

    # Dynamically safe update method


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

    result = bulk_location_update(tables_to_update, map_facility, counters)
 
    end_time = Time.now

    # Calculate durations and print summary
    puts "\n\n===== Update Complete ====="
    puts "Finished at: #{end_time.strftime('%Y-%m-%d %H:%M:%S')}"

    # Performance summary
    total_duration = end_time - start_time
    puts "\n--- Performance Summary ---"
    puts "Total Runtime: #{total_duration.round(2)} seconds"

    # Print update statistics for each model
    puts "\n--- Update Statistics ---"
    # Check results
    result.each do |table, counts|
      if counts[:error]
        puts "Error in #{table}: #{counts[:error]}"
      else
        puts "#{table}: Updated #{counts[:updated]} records, Skipped #{counts[:skipped]} records"
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