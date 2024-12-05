namespace :match do
  desc "Match facilities with locations based on name similarity"
  task facilities_locations: :environment do
    class FacilityLocationMatcher
      def initialize
        @matches = []
        @partial_matches = []
        @no_matches = []
        @match_threshold = 0.7 # Similarity threshold for full matches
        @partial_match_threshold = 0.5 # Similarity threshold for partial matches
      end

      def perform
        puts "Starting facility-location matching process..."
        
        # Fetch all facilities and locations
        facilities = Facility.all
        locations = Location.all

        # Perform matching
        facilities.each do |facility|
          match_facility(facility, locations)
        end

        # Display results
        display_results
      end

      private

      def match_facility(facility, locations)
        # Normalize facility name
        normalized_facility_name = normalize_name(facility.name)

        # Find exact matches
        exact_matches = locations.select do |location| 
          normalize_name(location.name) == normalized_facility_name
        end

        # Find full matches (high similarity)
        full_matches = locations.select do |location|
          name_similarity(normalized_facility_name, normalize_name(location.name)) >= @match_threshold
        end

        # Find partial matches
        partial_matches = locations.select do |location|
          normalized_location_name = normalize_name(location.name)
          normalized_facility_name.include?(normalized_location_name) ||
          normalized_location_name.include?(normalized_facility_name)
        end

        # Record matches
        if exact_matches.any?
          exact_matches.each do |match|
            @matches << {
              facility_id: facility.id,
              facility_name: facility.name,
              location_id: match.id,
              location_name: match.name,
              match_type: 'Exact'
            }
          end
        elsif full_matches.any?
          full_matches.each do |match|
            @matches << {
              facility_id: facility.id,
              facility_name: facility.name,
              location_id: match.id,
              location_name: match.name,
              match_type: 'Full'
            }
          end
        elsif partial_matches.any?
          partial_matches.each do |match|
            @partial_matches << {
              facility_id: facility.id,
              facility_name: facility.name,
              location_id: match.id,
              location_name: match.name,
              match_type: 'Partial'
            }
          end
        else
          @no_matches << {
            facility_id: facility.id,
            facility_name: facility.name
          }
        end
      end

      def normalize_name(name)
        # Remove special characters, convert to lowercase, trim
        name.to_s.downcase
          .gsub(/[^a-z0-9\s]/i, '')  # Remove special characters
          .strip
      end

      def name_similarity(str1, str2)
        # Simple similarity calculation using common substring
        longer = [str1, str2].max_by(&:length)
        shorter = [str1, str2].min_by(&:length)

        # Calculate Jaccard similarity
        intersection = shorter.chars.select { |char| longer.include?(char) }.uniq
        union = (str1.chars + str2.chars).uniq

        intersection.length.to_f / union.length
      end

      def display_results
        puts "\nMatching Results:"
        puts "Total Facilities: #{Facility.count}"
        puts "Exact/Full Matches: #{@matches.count}"
        puts "Partial Matches: #{@partial_matches.count}"
        puts "No Matches: #{@no_matches.count}"

        # Output matches to CSV for further investigation
        output_matches_to_csv
      end

      def output_matches_to_csv
        # Exact/Full Matches CSV
        CSV.open(Rails.root.join('tmp', 'facility_location_matches.csv'), 'w') do |csv|
          csv << ['Facility ID', 'Facility Name', 'Location ID', 'Location Name', 'Match Type']
          @matches.each do |match|
            csv << [
              match[:facility_id], 
              match[:facility_name], 
              match[:location_id], 
              match[:location_name], 
              match[:match_type]
            ]
          end
        end

        # Partial Matches CSV
        CSV.open(Rails.root.join('tmp', 'facility_location_partial_matches.csv'), 'w') do |csv|
          csv << ['Facility ID', 'Facility Name', 'Location ID', 'Location Name', 'Match Type']
          @partial_matches.each do |match|
            csv << [
              match[:facility_id], 
              match[:facility_name], 
              match[:location_id], 
              match[:location_name], 
              match[:match_type]
            ]
          end
        end

        # No Matches CSV
        CSV.open(Rails.root.join('tmp', 'facility_location_no_matches.csv'), 'w') do |csv|
          csv << ['Facility ID', 'Facility Name']
          @no_matches.each do |no_match|
            csv << [
              no_match[:facility_id], 
              no_match[:facility_name]
            ]
          end
        end

        puts "\nMatch results exported to:"
        puts "- tmp/facility_location_matches.csv"
        puts "- tmp/facility_location_partial_matches.csv"
        puts "- tmp/facility_location_no_matches.csv"
      end
    end

    # Require CSV for output
    require 'csv'

    # Run the matching process
    matcher = FacilityLocationMatcher.new
    matcher.perform
  end
end