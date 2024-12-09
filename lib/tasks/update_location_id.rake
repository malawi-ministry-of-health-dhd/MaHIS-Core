# lib/tasks/update_location_id.rake
namespace :users do
  desc 'Update user, observation, encounter, and pharmacy batch location IDs based on a predefined mapping'
  task update_location_id: :environment do
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
      984  => "ZA230235", 844  => "LL040434", 700  => "",
    }

    # Counters for tracking updates
    user_updated_count = 0
    user_skipped_count = 0
    obs_updated_count = 0
    obs_skipped_count = 0
    encounter_updated_count = 0
    encounter_skipped_count = 0
    pharmacy_batch_updated_count = 0
    pharmacy_batch_skipped_count = 0

    # Performance tracking
    user_update_start = Time.now
    obs_update_start = nil
    encounter_update_start = nil
    pharmacy_batch_update_start = nil

    puts "\n===== Location ID Update Process ====="
    puts "Started at: #{start_time.strftime('%Y-%m-%d %H:%M:%S')}"
    puts "Total location mappings to process: #{map_facility.size}"

    # Update Users
    puts "\n--- Updating Users ---"
    map_facility.each do |old_location_id, new_facility_code|
      # Find users with the matching location_id
      users = User.where(location_id: old_location_id)
      
      users.each do |user|
        # Update the location_id
        user.location_id = new_facility_code
        
        if user.save
          user_updated_count += 1
          print "."
        else
          user_skipped_count += 1
          puts "\nFailed to update user #{user.id}: #{user.errors.full_messages.join(', ')}"
        end
      end
    end

    user_update_end = Time.now
    obs_update_start = Time.now

    # Update Observations
    puts "\n\n--- Updating Observations ---"
    map_facility.each do |old_location_id, new_facility_code|
      # Find observations with the matching location_id
      observations = Observation.where(location_id: old_location_id)
      
      observations.each do |obs|
        # Update the location_id
        obs.location_id = new_facility_code
        
        if obs.save
          obs_updated_count += 1
          print "."
        else
          obs_skipped_count += 1
          puts "\nFailed to update observation #{obs.id}: #{obs.errors.full_messages.join(', ')}"
        end
      end
    end

    obs_update_end = Time.now
    encounter_update_start = Time.now

    # Update Encounters
    puts "\n\n--- Updating Encounters ---"
    map_facility.each do |old_location_id, new_facility_code|
      # Find encounters with the matching location_id
      encounters = Encounter.where(location_id: old_location_id)
      
      encounters.each do |encounter|
        # Update the location_id
        encounter.location_id = new_facility_code
        
        if encounter.save
          encounter_updated_count += 1
          print "."
        else
          encounter_skipped_count += 1
          puts "\nFailed to update Encounter #{encounter.id}: #{encounter.errors.full_messages.join(', ')}"
        end
      end
    end

    encounter_update_end = Time.now
    pharmacy_batch_update_start = Time.now

    # Update PharmacyBatches
    puts "\n\n--- Updating PharmacyBatches ---"
    map_facility.each do |old_location_id, new_facility_code|
      # Find pharmacy batches with the matching location_id
      pharmacy_batches = PharmacyBatch.where(location_id: old_location_id)
      
      pharmacy_batches.each do |batch|
        # Update the location_id
        batch.location_id = new_facility_code
        
        if batch.save
          pharmacy_batch_updated_count += 1
          print "."
        else
          pharmacy_batch_skipped_count += 1
          puts "\nFailed to update PharmacyBatch #{batch.id}: #{batch.errors.full_messages.join(', ')}"
        end
      end
    end

    pharmacy_batch_update_end = Time.now
    end_time = Time.now

    # Calculate durations
    user_update_duration = user_update_end - user_update_start
    obs_update_duration = obs_update_end - obs_update_start
    encounter_update_duration = encounter_update_end - encounter_update_start
    pharmacy_batch_update_duration = pharmacy_batch_update_end - pharmacy_batch_update_start
    total_duration = end_time - start_time

    # Print summary
    puts "\n\n===== Update Complete ====="
    puts "Finished at: #{end_time.strftime('%Y-%m-%d %H:%M:%S')}"
    puts "\n--- Performance Summary ---"
    puts "Total Runtime: #{total_duration.round(2)} seconds"
    puts "User Update Duration: #{user_update_duration.round(2)} seconds"
    puts "Observation Update Duration: #{obs_update_duration.round(2)} seconds"
    puts "Encounter Update Duration: #{encounter_update_duration.round(2)} seconds"
    puts "PharmacyBatch Update Duration: #{pharmacy_batch_update_duration.round(2)} seconds"
    
    puts "\n--- Update Statistics ---"
    puts "Users updated: #{user_updated_count}"
    puts "Users skipped: #{user_skipped_count}"
    puts "Observations updated: #{obs_updated_count}"
    puts "Observations skipped: #{obs_skipped_count}"
    puts "Encounters updated: #{encounter_updated_count}"
    puts "Encounters skipped: #{encounter_skipped_count}"
    puts "PharmacyBatches updated: #{pharmacy_batch_updated_count}"
    puts "PharmacyBatches skipped: #{pharmacy_batch_skipped_count}"

    # Memory usage (if possible)
    if defined?(Process)
      memory_usage = `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
      puts "\n--- System Resources ---"
      puts "Memory Usage: #{memory_usage.round(2)} MB"
    end
  end
end