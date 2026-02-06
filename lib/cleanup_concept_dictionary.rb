#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to clean up JSON syntax errors in ConceptNameDictionary.json
# Usage: rails runner lib/cleanup_concept_dictionary.rb

require 'json'

class ConceptDictionaryCleanup
  DICTIONARY_PATH = Rails.root.join('config', 'ConceptNameDictionary.json')
  BACKUP_PATH = Rails.root.join('config', "ConceptNameDictionary.json.dirty_backup.#{Time.now.strftime('%Y%m%d_%H%M%S')}")

  def initialize
    @fixes_applied = []
  end

  def run
    puts "Starting JSON cleanup for ConceptNameDictionary..."
    puts "Reading file from: #{DICTIONARY_PATH}"

    # Read the raw content
    raw_content = read_raw_content
    
    # Create backup
    create_backup(raw_content)

    # Clean up the content
    cleaned_content = clean_json_content(raw_content)

    # Parse and validate
    dictionary = parse_cleaned_content(cleaned_content)

    # Write cleaned version
    save_cleaned_dictionary(dictionary)

    # Print summary
    print_summary
  end

  private

  def read_raw_content
    unless File.exist?(DICTIONARY_PATH)
      raise "Dictionary file not found at: #{DICTIONARY_PATH}"
    end

    File.read(DICTIONARY_PATH)
  end

  def create_backup(content)
    File.write(BACKUP_PATH, content)
    puts "Dirty backup created at: #{BACKUP_PATH}"
  end

  def clean_json_content(content)
    puts "\nApplying JSON cleanup fixes..."
    
    # Fix 1: Convert single quotes to double quotes for strings
    content = fix_single_quotes(content)
    
    # Fix 2: Remove trailing commas before closing braces/brackets
    content = fix_trailing_commas(content)
    
    # Fix 3: Ensure proper comma placement between objects
    content = fix_missing_commas(content)
    
    # Fix 4: Fix malformed property names
    content = fix_property_names(content)
    
    # Fix 5: Remove extra commas
    content = fix_extra_commas(content)

    content
  end

  def fix_single_quotes(content)
    # Track this fix
    original_single_quotes = content.scan(/'[^']*'/).length
    
    # Convert single quotes to double quotes for property names and string values
    # But be careful not to convert single quotes inside string content
    content = content.gsub(/:\s*'([^']*)'/, ': "\1"')  # Fix string values
    content = content.gsub(/\[\s*'([^']*)'/, '["\\1"')  # Fix array values start
    content = content.gsub(/,\s*'([^']*)'/, ', "\\1"')  # Fix array values middle
    content = content.gsub(/'([^']*)',?\s*\]/, '"\\1"]')  # Fix array values end
    
    new_single_quotes = content.scan(/'[^']*'/).length
    fixed_count = original_single_quotes - new_single_quotes
    
    if fixed_count > 0
      @fixes_applied << "Fixed #{fixed_count} single quote issues"
    end
    
    content
  end

  def fix_trailing_commas(content)
    before_count = content.scan(/,\s*[}\]]/).length
    
    # Remove trailing commas before closing braces and brackets
    content = content.gsub(/,(\s*[}\]])/, '\1')
    
    after_count = content.scan(/,\s*[}\]]/).length
    fixed_count = before_count - after_count
    
    if fixed_count > 0
      @fixes_applied << "Removed #{fixed_count} trailing commas"
    end
    
    content
  end

  def fix_missing_commas(content)
    before_fixes = content.dup
    
    # Add missing commas between objects
    content = content.gsub(/}\s*\n\s*{/, "},\n   {")
    
    # Add missing commas after string/number values before next property
    content = content.gsub(/("\w*")\s*\n\s*("\w*":)/, "\\1,\n      \\2")
    content = content.gsub(/(\d+)\s*\n\s*("\w*":)/, "\\1,\n      \\2")
    
    if content != before_fixes
      @fixes_applied << "Added missing commas between objects/properties"
    end
    
    content
  end

  def fix_property_names(content)
    before_fixes = content.dup
    
    # Ensure property names are properly quoted
    content = content.gsub(/(\s*)([a-zA-Z_][a-zA-Z0-9_]*)\s*:/, '\1"\2":')
    
    # Fix already quoted property names (remove double quotes)
    content = content.gsub(/"\s*"\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*"\s*":/, '"\1":')
    
    if content != before_fixes
      @fixes_applied << "Fixed property name formatting"
    end
    
    content
  end

  def fix_extra_commas(content)
    before_count = content.scan(/,,+/).length
    
    # Remove double commas
    content = content.gsub(/,,+/, ',')
    
    # Remove comma at start of array/object
    content = content.gsub(/([{\[])\s*,/, '\1')
    
    after_count = content.scan(/,,+/).length
    fixed_count = before_count - after_count
    
    if fixed_count > 0
      @fixes_applied << "Removed #{fixed_count} extra commas"
    end
    
    content
  end

  def parse_cleaned_content(content)
    puts "\nParsing cleaned JSON..."
    
    begin
      dictionary = JSON.parse(content)
      puts "✅ JSON parsing successful!"
      puts "   Found #{dictionary.length} concept entries"
      dictionary
    rescue JSON::ParserError => e
      puts "❌ JSON parsing still failed: #{e.message}"
      
      # Try to give more context about the error
      lines = content.lines
      error_line = e.message[/line (\d+)/, 1]
      if error_line
        line_num = error_line.to_i
        puts "\nContext around error (line #{line_num}):"
        start_line = [line_num - 3, 1].max
        end_line = [line_num + 2, lines.length].min
        
        (start_line..end_line).each do |i|
          marker = i == line_num ? ">>> " : "    "
          puts "#{marker}#{i}: #{lines[i-1]}"
        end
      end
      
      raise "Unable to parse JSON even after cleanup. Manual intervention may be required."
    end
  end

  def save_cleaned_dictionary(dictionary)
    # Write the properly formatted JSON
    cleaned_json = JSON.pretty_generate(dictionary)
    File.write(DICTIONARY_PATH, cleaned_json)
    puts "\n✅ Cleaned dictionary saved to: #{DICTIONARY_PATH}"
  end

  def print_summary
    puts "\n" + "=" * 60
    puts "JSON CLEANUP SUMMARY"
    puts "=" * 60
    
    if @fixes_applied.any?
      puts "Fixes applied:"
      @fixes_applied.each { |fix| puts "  - #{fix}" }
    else
      puts "No fixes were needed - JSON was already clean!"
    end
    
    puts "\nBackup of original file: #{BACKUP_PATH}"
    puts "=" * 60
  end
end

# Run the cleanup if executed directly
if __FILE__ == $PROGRAM_NAME || caller.any? { |line| line.include?('rails/commands/runner') }
  begin
    ConceptDictionaryCleanup.new.run
  rescue StandardError => e
    puts "\nERROR: #{e.message}"
    puts e.backtrace.first(10).join("\n") if e.backtrace
    exit 1
  end
end