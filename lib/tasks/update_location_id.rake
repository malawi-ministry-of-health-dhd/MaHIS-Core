# lib/tasks/update_location_id.rake
# rails users:update_location_id
namespace :users do
  desc 'Update user location IDs based on a predefined mapping'
  task update_location_id: :environment do
    # Mapping of location IDs to new facility codes
    map_facility = {
      582  => "NT121225",
      583  => "NT121225",
      584  => "NT121225",
      6    => "LL040007",
      100  => "MC010259",
      1007 => "MG200808",
      1018 => "MG200218",
      1021 => "CR260018",
      1049 => "KU070588",
      1060 => "BT240028",
      1096 => "BT241813",
      11   => "BK170053",
      1116 => "MC010618",
      1119 => "NT081005",
      1120 => "MC010098",
      1121 => "NT120186",
      1132 => "MC010407",
      1133 => "MC010898",
      12   => "BK170053",
      126  => "LL040298",
      139  => "DE030334",
      140  => "DE030334",
      20   => "NT120080",
      203  => "MC010494",
      222  => "NT120534",
      230  => "MC010551",
      237  => "NK100562",
      238  => "MG201537",
      239  => "NK100562",
      24   => "BT241814",
      248  => "NT120581",
      26   => "BT241814",
      269  => "MC010618",
      278  => "MG200636",
      279  => "MC010637",
      294  => "LL040122",
      307  => "MC010711",
      347  => "LL040805",
      359  => "MG200829",
      36   => "NT120123",
      398  => "MC010898",
      399  => "MC010898",
      4    => "SA091309",
      401  => "MC010898",
      402  => "SA090899",
      410  => "MC010925",
      420  => "MC010947",
      454  => "DA021013",
      499  => "MZ161098",
      5    => "LL040012",
      516  => "MC011131",
      567  => "MC011206",
      679  => "NT121219",
      614  => "BT241293",
      579  => "NT121219",
      621  => "SA091312",
      622  => "SA091312",
      658  => "MC011397",
      696  => "LL040529",
      712  => "LL040996",
      717  => "MZ160760",
      75   => "LL040214",
      8    => "LL040033",
      851  => "LL040010",
      857  => "LL040016",
      868  => "LL040316",
      874  => "MC011376",
      875  => "MC010441",
      877  => "MC011131",
      905  => "CK270069",
      914  => "TH310026",
      968  => "BK170054",
      984  => "ZA230235",
    }

    # Counter for tracking updates
    updated_count = 0
    skipped_count = 0

    # Iterate through the mapping
    map_facility.each do |old_location_id, new_facility_code|
      # Find users with the matching location_id
      users = User.where(location_id: old_location_id)
      
      users.each do |user|
        # Update the facility code
        user.location_id = new_facility_code
        
        if user.save
          updated_count += 1
          puts "Updated user #{user.id} with facility #{new_facility_code}"
        else
          skipped_count += 1
          puts "Failed to update user #{user.id}: #{user.errors.full_messages.join(', ')}"
        end
      end
    end

    # Print summary
    puts "\nUpdate complete:"
    puts "Total users updated: #{updated_count}"
    puts "Total users skipped: #{skipped_count}"
  end
end