#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to sync ConceptNameDictionary.json with current concept names from the database
# Usage: rails runner lib/sync_concept_dictionary.rb

require 'json'

class ConceptDictionarySync
  DICTIONARY_PATH = Rails.root.join('config', 'ConceptNameDictionary.json')
  BACKUP_PATH = Rails.root.join('config', "ConceptNameDictionary.json.backup.#{Time.now.strftime('%Y%m%d_%H%M%S')}")

  def initialize
    @updated_count = 0
    @missing_count = 0
    @unchanged_count = 0
  end

  def run
    puts "Starting concept dictionary sync..."
    puts "Reading dictionary from: #{DICTIONARY_PATH}"

    # Read the current dictionary
    dictionary = load_dictionary

    puts "Found #{dictionary.length} entries in dictionary"

    # Create backup
    create_backup(dictionary)

    # Update concept names from database
    updated_dictionary = update_concept_names(dictionary)

    # Write back to file
    save_dictionary(updated_dictionary)

    # Print summary
    print_summary
  end

  private

  def load_dictionary
    unless File.exist?(DICTIONARY_PATH)
      raise "Dictionary file not found at: #{DICTIONARY_PATH}"
    end

    JSON.parse(File.read(DICTIONARY_PATH))
  rescue JSON::ParserError => e
    raise "Failed to parse JSON file: #{e.message}"
  end

  def create_backup(dictionary)
    File.write(BACKUP_PATH, JSON.pretty_generate(dictionary))
    puts "Backup created at: #{BACKUP_PATH}"
  end

  def update_concept_names(dictionary)
    puts "\nUpdating concept names from database..."

    dictionary.map do |entry|
      concept_id = entry['concept_id']
      old_name = entry['name']

      # Find the concept name from the database
      # In OpenMRS, we want the preferred name (usually tagged as 'default' or 'preferred')
      concept_name = find_preferred_concept_name(concept_id)

      if concept_name
        new_name = concept_name.name

        if old_name != new_name
          puts "  [#{concept_id}] Updating: '#{old_name}' -> '#{new_name}'"
          entry['name'] = new_name
          @updated_count += 1
        else
          @unchanged_count += 1
        end
      else
        puts "  [#{concept_id}] WARNING: Concept not found in database (keeping '#{old_name}')"
        @missing_count += 1
      end

      entry
    end
  end

  def find_preferred_concept_name(concept_id)
    # Try to find the preferred/default name first
    concept_name = ConceptName.where(concept_id: concept_id, voided: 0)
                              .where("locale = 'en' OR locale LIKE 'en_%'")
                              .order(Arel.sql("FIELD(concept_name_type, 'FULLY_SPECIFIED', 'SHORT', 'INDEX_TERM') DESC"))
                              .first

    # If no English name found, try any locale
    concept_name ||= ConceptName.where(concept_id: concept_id, voided: 0)
                                .order(Arel.sql("FIELD(concept_name_type, 'FULLY_SPECIFIED', 'SHORT', 'INDEX_TERM') DESC"))
                                .first

    concept_name
  end

  def save_dictionary(dictionary)
    File.write(DICTIONARY_PATH, JSON.pretty_generate(dictionary))
    puts "\nDictionary updated successfully at: #{DICTIONARY_PATH}"
  end

  def print_summary
    puts "\n" + "=" * 60
    puts "SYNC SUMMARY"
    puts "=" * 60
    puts "Updated:   #{@updated_count} concepts"
    puts "Unchanged: #{@unchanged_count} concepts"
    puts "Missing:   #{@missing_count} concepts (not found in database)"
    puts "=" * 60
  end
end

# Run the sync if executed directly
if __FILE__ == $PROGRAM_NAME || caller.any? { |line| line.include?('rails/commands/runner') }
  begin
    ConceptDictionarySync.new.run
  rescue StandardError => e
    puts "\nERROR: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    exit 1
  end
end
