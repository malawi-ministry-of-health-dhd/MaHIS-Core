#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to remap concept IDs in ConceptNameDictionary.json by matching concept names
# Usage: rails runner lib/remap_concept_ids.rb

require 'json'

class ConceptIdRemapper
  DICTIONARY_PATH = Rails.root.join('config', 'ConceptNameDictionary.json')
  BACKUP_PATH = Rails.root.join('config', "ConceptNameDictionary.json.backup.#{Time.now.strftime('%Y%m%d_%H%M%S')}")

  def initialize
    @updated_count = 0
    @exact_matches = 0
    @fuzzy_matches = 0
    @no_matches = 0
    @skipped_retired = 0
    @json_cleaned = false
  end

  def run
    puts "Starting concept ID remapping..."
    puts "Reading dictionary from: #{DICTIONARY_PATH}"

    # First, clean up the JSON file to fix any syntax issues
    cleanup_json_file

    # Read the current dictionary
    dictionary = load_dictionary

    puts "Found #{dictionary.length} entries in dictionary"

    # Create backup
    create_backup(dictionary)

    # Update concept IDs from database
    updated_dictionary = remap_concept_ids(dictionary)

    # Write back to file
    save_dictionary(updated_dictionary)

    # Print summary
    print_summary
  end

  private

  def cleanup_json_file
    puts "\nCleaning up JSON file..."
    
    unless File.exist?(DICTIONARY_PATH)
      puts "Dictionary file not found at: #{DICTIONARY_PATH}"
      return
    end

    content = File.read(DICTIONARY_PATH)
    original_content = content.dup
    
    # First try to parse as-is
    begin
      JSON.parse(content)
      puts "  - JSON is already valid ✅"
      return
    rescue JSON::ParserError => e
      puts "  - JSON validation failed: #{e.message[0..100]}"
      puts "  - Attempting cleanup..."
    end
    
    # Create a backup before attempting cleanup
    backup_path = DICTIONARY_PATH.to_s + ".cleanup_backup.#{Time.now.strftime('%Y%m%d_%H%M%S')}"
    File.write(backup_path, original_content)
    puts "  - Backup created: #{File.basename(backup_path)}"
    
    # Try manual line-by-line cleanup
    content = perform_careful_cleanup(content)
    
    # Validate the cleaned JSON
    begin
      JSON.parse(content)
      puts "  - JSON validation: ✅"
      
      File.write(DICTIONARY_PATH, content)
      puts "  - File updated with cleaned JSON"
      @json_cleaned = true
      
    rescue JSON::ParserError => e
      puts "  - JSON cleanup failed: #{e.message[0..100]}"
      
      # Restore from backup
      File.write(DICTIONARY_PATH, original_content)
      puts "  - Original file restored"
      
      raise "JSON cleanup failed: #{e.message}. Please fix the JSON manually."
    end
  end

  def perform_careful_cleanup(content)
    lines = content.split("\n")
    cleaned_lines = []
    
    puts "  - Processing #{lines.length} lines..."
    
    lines.each_with_index do |line, index|
      original_line = line.dup
      
      # Fix single quotes to double quotes in property names and values
      line = line.gsub(/:\s*'([^']*)'/, ': "\1"')  # property values
      line = line.gsub(/'([^']*)'(\s*:)/, '"\1"\2') # property names
      
      # Fix array elements with single quotes
      line = line.gsub(/\[\s*'/, '["')
      line = line.gsub(/',\s*'/, '", "')
      line = line.gsub(/'\s*\]/, '"]')
      
      # Handle missing commas in arrays
      next_line = lines[index + 1]
      if next_line && is_array_element_missing_comma?(line, next_line)
        line = line.rstrip + ','
      end
      
      # Check if we need a comma after this line (for object properties)
      if next_line && should_add_comma?(line, next_line)
        line = line.rstrip + ','
      end
      
      # Remove trailing commas before closing brackets/braces
      if line.strip.match?(/,\s*$/) && next_line && next_line.strip.match?(/^[}\]]/)
        line = line.gsub(/,\s*$/, '')
      end
      
      cleaned_lines << line
      
      # Debug output for problematic lines
      if original_line != line
        puts "    [#{index + 1}] Fixed: #{original_line.strip} → #{line.strip}"
      end
    end
    
    cleaned_lines.join("\n")
  end
  
  def is_array_element_missing_comma?(current_line, next_line)
    # Check if current line is an array element (quoted string) without comma
    # and next line is also an array element
    current_line.strip.match?(/^\s*"[^"]*"\s*$/) &&
    next_line.strip.match?(/^\s*"[^"]*"/) &&
    !current_line.strip.end_with?(',')
  end
  
  def should_add_comma?(current_line, next_line)
    # Don't add comma if line already has one
    return false if current_line.strip.end_with?(',')
    
    # Don't add comma before closing braces/brackets
    return false if next_line.strip.match?(/^[}\]]/)
    
    # Don't add comma if current line ends with opening brace/bracket (start of object/array)
    return false if current_line.strip.end_with?('{', '[')
    
    # Add comma if current line has a complete property value and next line has a property
    current_line.strip.match?(/^"[^"]*":\s*(".*"|\d+|true|false|null|\])\s*$/) && 
    next_line.strip.match?(/^"[^"]*":/)
  end

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

  def remap_concept_ids(dictionary)
    puts "\nRemapping concept IDs from database..."
    puts "Looking for matches (non-retired concepts only)..."

    dictionary.map.with_index do |entry, index|
      concept_name = entry['name']
      old_concept_id = entry['concept_id']

      next entry if concept_name.blank?

      print "  [#{index + 1}/#{dictionary.length}] '#{concept_name}' (was ID: #{old_concept_id}) ... "

      # Find matching concept in database
      matched_concept = find_matching_concept(concept_name)

      if matched_concept
        new_concept_id = matched_concept[:concept_id]
        match_type = matched_concept[:match_type]
        matched_name = matched_concept[:matched_name]

        if old_concept_id != new_concept_id
          puts "#{match_type} match! ID: #{old_concept_id} -> #{new_concept_id} (name: '#{matched_name}')"
          entry['concept_id'] = new_concept_id
          @updated_count += 1
          
          case match_type
          when 'EXACT'
            @exact_matches += 1
          when 'FUZZY'
            @fuzzy_matches += 1
          end
        else
          puts "already correct (#{match_type} match)"
          case match_type
          when 'EXACT'
            @exact_matches += 1
          when 'FUZZY'
            @fuzzy_matches += 1
          end
        end
      else
        puts "no match found"
        @no_matches += 1
      end

      entry
    end
  end

  def find_matching_concept(name)
    # First try exact match (case insensitive)
    exact_match = find_exact_match(name)
    return exact_match if exact_match

    # Then try fuzzy matching 
    fuzzy_match = find_fuzzy_match(name)
    return fuzzy_match if fuzzy_match

    nil
  end

  def find_exact_match(name)
    # Query for exact match on non-retired, non-voided concepts
    concept_name = ConceptName.joins(:concept)
                             .where(concept_name: { voided: 0 })
                             .where(concept: { retired: 0 })
                             .where('LOWER(concept_name.name) = ?', name.downcase)
                             .first

    return nil unless concept_name

    {
      concept_id: concept_name.concept_id,
      matched_name: concept_name.name,
      match_type: 'EXACT'
    }
  end

  def find_fuzzy_match(name)
    # Get all non-retired, non-voided concept names for fuzzy matching
    # Note: We need to include concept_name_id (primary key) for find_each to work
    candidate_concepts = ConceptName.joins(:concept)
                                  .where(concept_name: { voided: 0 })
                                  .where(concept: { retired: 0 })

    best_match = nil
    best_score = 0

    candidate_concepts.find_each do |concept_name|
      score = calculate_similarity(name, concept_name.name)
      
      # Require at least 70% similarity for a fuzzy match
      if score > 0.70 && score > best_score
        best_match = concept_name
        best_score = score
      end
    end

    return nil unless best_match

    {
      concept_id: best_match.concept_id,
      matched_name: best_match.name,
      match_type: 'FUZZY'
    }
  end

  def calculate_similarity(str1, str2)
    # Normalize strings: downcase and remove extra whitespace
    s1 = str1.downcase.strip.squeeze(' ')
    s2 = str2.downcase.strip.squeeze(' ')

    # If one is contained in the other, higher score
    if s1.include?(s2) || s2.include?(s1)
      shorter_length = [s1.length, s2.length].min
      longer_length = [s1.length, s2.length].max
      return shorter_length.to_f / longer_length
    end

    # Use Levenshtein distance for similarity
    levenshtein_similarity(s1, s2)
  end

  def levenshtein_similarity(str1, str2)
    # Calculate Levenshtein distance
    distance = levenshtein_distance(str1, str2)
    max_length = [str1.length, str2.length].max
    
    # Convert distance to similarity (0.0 to 1.0)
    return 1.0 if max_length == 0
    (max_length - distance).to_f / max_length
  end

  def levenshtein_distance(str1, str2)
    matrix = Array.new(str1.length + 1) { Array.new(str2.length + 1) }

    (0..str1.length).each { |i| matrix[i][0] = i }
    (0..str2.length).each { |j| matrix[0][j] = j }

    (1..str1.length).each do |i|
      (1..str2.length).each do |j|
        cost = str1[i - 1] == str2[j - 1] ? 0 : 1
        matrix[i][j] = [
          matrix[i - 1][j] + 1,      # deletion
          matrix[i][j - 1] + 1,      # insertion
          matrix[i - 1][j - 1] + cost # substitution
        ].min
      end
    end

    matrix[str1.length][str2.length]
  end

  def save_dictionary(dictionary)
    File.write(DICTIONARY_PATH, JSON.pretty_generate(dictionary))
    puts "\nDictionary updated successfully at: #{DICTIONARY_PATH}"
  end

  def print_summary
    puts "\n" + "=" * 70
    puts "CONCEPT ID REMAPPING SUMMARY"
    puts "=" * 70
    puts "JSON cleaned:     #{@json_cleaned ? 'Yes' : 'No'}"
    puts "Total updated:    #{@updated_count} concept IDs"
    puts "Exact matches:    #{@exact_matches} concepts"
    puts "Fuzzy matches:    #{@fuzzy_matches} concepts"
    puts "No matches:       #{@no_matches} concepts"
    puts "Skipped retired:  #{@skipped_retired} concepts"
    puts "=" * 70
    puts
    puts "Backup created at: #{BACKUP_PATH}"
    
    if @no_matches > 0
      puts "\nWARNING: #{@no_matches} concepts could not be matched."
      puts "Review the output above to see which concepts need manual attention."
    end
  end
end

# Run the remapping if executed directly
if __FILE__ == $PROGRAM_NAME || caller.any? { |line| line.include?('rails/commands/runner') }
  begin
    ConceptIdRemapper.new.run
  rescue StandardError => e
    puts "\nERROR: #{e.message}"
    puts e.backtrace.first(10).join("\n")
    exit 1
  end
end