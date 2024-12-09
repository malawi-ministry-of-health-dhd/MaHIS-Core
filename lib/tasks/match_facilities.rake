namespace :match do
  desc "Match facilities with locations based on shared keywords"
  task facilities_locations: :environment do
    class FacilityLocationMatcher
      def initialize
        @matches = []
        @no_matches = []
      end

      def perform
        puts "Starting facility-location matching process..."
        
        facilities = Facility.all
        locations = Location.all

        facilities.each do |facility|
          match_facility(facility, locations)
        end

        display_results
      end

      private

      def match_facility(facility, locations)

        # Extract key words from facility name
        facility_keywords = extract_keywords(facility.name)

        # Find matches based on shared keywords
        matching_locations = locations.select do |location|
          location_keywords = extract_keywords(location.name)
          
          # Check if there are at least two shared keywords
          (facility_keywords & location_keywords).size >= 2
        end

        # Record matches or no matches
        if matching_locations.any?
          matching_locations.each do |match|
            @matches << {
              facility_id: facility.id,
              facility_name: facility.name,
              location_id: match.id,
              location_name: match.name,
              shared_keywords: (extract_keywords(facility.name) & extract_keywords(match.name)).join(', ')
            }
          end
        else
          @no_matches << {
            facility_id: facility.id,
            facility_name: facility.name
          }
        end
      end

      def extract_keywords(name)
        # Normalize and split the name into words
        name.to_s.downcase
            .gsub(/[^\w\s]/, '')  # Remove special characters
            .split
            .reject { |word| common_words.include?(word) }  # Remove common words
      end

      def common_words
        # List of common words to ignore in matching
        ['clinic', 'hospital', 'center', 'centre', 'health', 'medical']
      end

      def display_results
        puts "\nMatching Results:"
        puts "Total Facilities: #{Facility.count}"
        puts "Matches Found: #{@matches.count}"
        puts "No Matches: #{@no_matches.count}"

        # Output matches to CSV
        output_matches_to_csv
      end

      def output_matches_to_csv
        # Matches CSV
        CSV.open(Rails.root.join('tmp', 'facility_location_matches.csv'), 'w') do |csv|
          csv << ['Facility ID', 'Facility Name', 'Location ID', 'Location Name', 'Shared Keywords']
          @matches.each do |match|
            csv << [
              match[:facility_id], 
              match[:facility_name], 
              match[:location_id], 
              match[:location_name],
              match[:shared_keywords]
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