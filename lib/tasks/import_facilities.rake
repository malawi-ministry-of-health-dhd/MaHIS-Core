# lib/tasks/import_facilities.rake
# rails import:facilities
# rails import:facilities:rollback
namespace :import do
    desc "Import facilities from JSON file with validation, backup, and data transformation"
    task facilities: :environment do
      require 'json'
      require 'fileutils'
  
      class FacilityImporter
        def initialize
          @json_file_path = Rails.root.join('db', 'data', 'facilities', 'facilities.json')
          @backup_dir = Rails.root.join('db', 'data', 'facilities', 'backups')
          @total = 0
          @imported = 0
          @failed = 0
          @errors = []
        end
  
        def perform
          validate_file_exists
          create_backup
          import_facilities
          display_results
        rescue StandardError => e
          puts "\nCritical Error: #{e.message}"
          restore_from_backup if @backup_path
        end
  
        private
  
        def validate_file_exists
          unless File.exist?(@json_file_path)
            raise "File not found at #{@json_file_path}"
          end
        end
  
        def create_backup
          FileUtils.mkdir_p(@backup_dir)
          timestamp = Time.current.strftime('%Y%m%d_%H%M%S')
          @backup_path = File.join(@backup_dir, "facilities_backup_#{timestamp}.json")
          FileUtils.cp(@json_file_path, @backup_path)
          puts "Backup created at #{@backup_path}"
  
          # Database backup
          Facility.find_each.with_index do |facility, index|
            facility_data = facility.attributes
            File.open(File.join(@backup_dir, "db_backup_#{timestamp}.json"), 'a') do |f|
              f.puts(facility_data.to_json)
            end
          end
        end
  
        def restore_from_backup
          puts "\nAttempting to restore from backup..."
          FileUtils.cp(@backup_path, @json_file_path)
          puts "Restored from #{@backup_path}"
        end
  
        def parse_date(date_string)
          return nil if date_string.blank?
  
          # Handle various date formats by removing ordinals and parsing
          date_string = date_string.gsub(/(st|nd|rd|th)/, '') # Remove ordinals
  
          begin
            if date_string.match?(/^\d{4}-\d{2}-\d{2}$/)
              Date.parse(date_string)
            else
              # Handle formats like "Jan 1 75" or "1st Jan 1975"
              Date.parse(date_string).strftime('%Y-%m-%d')
            end
          rescue Date::Error
            @errors << "Invalid date format: #{date_string}"
            nil
          end
        end
  
        def validate_facility_data(data)
          errors = []
          errors << "Missing code" if data['code'].blank?
          errors << "Missing name" if data['name'].blank?
          errors << "Invalid latitude" if data['latitude'].present? && !valid_latitude?(data['latitude'])
          errors << "Invalid longitude" if data['longitude'].present? && !valid_longitude?(data['longitude'])
          errors
        end
  
        def valid_latitude?(latitude)
          latitude.to_s.match?(/^-?([1-8]?[0-9](\.\d+)?|90(\.0+)?)$/) # Latitude range -90 to 90
        end
  
        def valid_longitude?(longitude)
          longitude.to_s.match?(/^-?([1-9]?[0-9]{1,2}(\.\d+)?|180(\.0+)?)$/) # Longitude range -180 to 180
        end
  
        def transform_facility_data(data)
          {
            code: clean_string(data['code']),
            name: clean_string(data['name']),
            common: clean_string(data['common']),
            ownership: clean_string(data['ownership']),
            facility_type: clean_string(data['type']),
            status: clean_string(data['status']),
            regulatory_status: clean_string(data['regulatoryStatus']),
            district: clean_string(data['district']),
            date_opened: parse_date(data['dateOpened']),
            latitude: clean_string(data['latitude']),
            longitude: clean_string(data['longitude'])
          }
        end
  
        def clean_string(value)
          value.to_s.strip # Trim leading and trailing spaces
        end
  
        def import_facilities
          puts "Starting facility import..."
  
          # Read and parse JSON
          json_content = JSON.parse(File.read(@json_file_path))
          facilities_data = json_content['data']
          @total = facilities_data.length
  
          # Wrap in transaction
          ActiveRecord::Base.transaction do
            facilities_data.each_with_index do |facility_data, index|
              import_facility(facility_data, index + 1)
            end
  
            # Raise an error if too many failures
            failure_threshold = 0.3 # 30%
            if @failed.to_f / @total > failure_threshold
              raise "Too many failures (#{@failed} out of #{@total}). Rolling back."
            end
          end
        end
  
        def import_facility(facility_data, index)
          # Validate data
          validation_errors = validate_facility_data(facility_data)
          if validation_errors.any?
            @failed += 1
            @errors << "Facility #{facility_data['code']}: #{validation_errors.join(', ')}"
            return
          end
  
          begin
            # Transform data
            transformed_data = transform_facility_data(facility_data)
  
            # Find or initialize facility
            facility = Facility.find_by(code: transformed_data[:code]) || Facility.new
  
            # Assign attributes and save
            facility.assign_attributes(transformed_data)
  
            if facility.save
              @imported += 1
              print '.' if index % 10 == 0
            else
              @failed += 1
              @errors << "Facility #{facility_data['code']}: #{facility.errors.full_messages.join(', ')}"
            end
  
          rescue => e
            @failed += 1
            @errors << "Facility #{facility_data['code']}: #{e.message}"
          end
        end
  
        def display_results
          puts "\n\nImport Summary:"
          puts "Total facilities in file: #{@total}"
          puts "Successfully imported/updated: #{@imported}"
          puts "Failed: #{@failed}"
  
          if @errors.any?
            puts "\nErrors encountered:"
            @errors.each { |error| puts "- #{error}" }
          end
  
          puts "\nBackup location: #{@backup_path}"
        end
      end
  
      # Run the import
      FacilityImporter.new.perform
    end
  
    desc "Rollback last facilities import using backup"
    task rollback_facilities: :environment do
      backup_dir = Rails.root.join('db', 'data', 'facilities', 'backups')
      latest_backup = Dir.glob(File.join(backup_dir, 'db_backup_*.json')).max_by { |f| File.mtime(f) }
  
      if latest_backup
        puts "Rolling back to backup: #{latest_backup}"
        # Clear existing facilities
        Facility.delete_all
  
        # Restore from backup
        File.readlines(latest_backup).each do |line|
          facility_data = JSON.parse(line)
          Facility.create!(facility_data)
        end
  
        puts "Rollback completed successfully"
      else
        puts "No backup found in #{backup_dir}"
      end
    end
  end
  