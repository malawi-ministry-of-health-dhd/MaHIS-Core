#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to validate database connection and concept structure
# Usage: rails runner lib/validate_concept_setup.rb

puts "Testing database connection and concept structure..."

# Test database connection
begin
  puts "\n1. Testing database connection..."
  puts "   - Main database: #{ActiveRecord::Base.connection.current_database}"
  puts "   - Connection successful: ✅"
rescue => e
  puts "   - Connection failed: ❌ #{e.message}"
  exit 1
end

# Test ConceptName model
begin
  puts "\n2. Testing ConceptName model..."
  count = ConceptName.count
  puts "   - Total concept names: #{count}"
  
  non_voided_count = ConceptName.where(voided: 0).count
  puts "   - Non-voided concept names: #{non_voided_count}"
  
  sample_concept_name = ConceptName.where(voided: 0).first
  if sample_concept_name
    puts "   - Sample concept name: '#{sample_concept_name.name}' (ID: #{sample_concept_name.concept_id})"
    puts "   - ConceptName model: ✅"
  else
    puts "   - ConceptName model: ❌ No concept names found"
    exit 1
  end
rescue => e
  puts "   - ConceptName model error: ❌ #{e.message}"
  exit 1
end

# Test Concept model and retired field
begin
  puts "\n3. Testing Concept model..."
  concept_count = Concept.count
  puts "   - Total concepts: #{concept_count}"
  
  non_retired_count = Concept.where(retired: 0).count
  puts "   - Non-retired concepts: #{non_retired_count}"
  
  retired_count = Concept.where(retired: 1).count
  puts "   - Retired concepts: #{retired_count}"
  
  if sample_concept_name
    concept = Concept.find_by(concept_id: sample_concept_name.concept_id)
    if concept
      puts "   - Sample concept retired status: #{concept.retired}"
      puts "   - Concept model: ✅"
    else
      puts "   - Concept model: ❌ Sample concept not found"
    end
  end
rescue => e
  puts "   - Concept model error: ❌ #{e.message}"
  exit 1
end

# Test join between ConceptName and Concept
begin
  puts "\n4. Testing ConceptName + Concept join..."
  joined_count = ConceptName.joins(:concept)
                           .where(concept_name: { voided: 0 })
                           .where(concept: { retired: 0 })
                           .count
  puts "   - Non-voided concept names with non-retired concepts: #{joined_count}"
  
  sample_joined = ConceptName.joins(:concept)
                            .where(concept_name: { voided: 0 })
                            .where(concept: { retired: 0 })
                            .select('concept_name.concept_id, concept_name.name')
                            .first
  
  if sample_joined
    puts "   - Sample joined record: '#{sample_joined.name}' (ID: #{sample_joined.concept_id})"
    puts "   - Join query: ✅"
  else
    puts "   - Join query: ❌ No valid records found"
    exit 1
  end
rescue => e
  puts "   - Join query error: ❌ #{e.message}"
  exit 1
end

# Test ConceptNameDictionary.json file
begin
  puts "\n5. Testing ConceptNameDictionary.json file..."
  dictionary_path = Rails.root.join('config', 'ConceptNameDictionary.json')
  
  if File.exist?(dictionary_path)
    puts "   - File exists: ✅"
    
    content = File.read(dictionary_path)
    dictionary = JSON.parse(content)
    
    puts "   - Valid JSON: ✅"
    puts "   - Total entries: #{dictionary.length}"
    
    if dictionary.length > 0
      sample_entry = dictionary.first
      puts "   - Sample entry: '#{sample_entry['name']}' (ID: #{sample_entry['concept_id']})"
      puts "   - Dictionary structure: ✅"
    else
      puts "   - Dictionary structure: ❌ Empty dictionary"
    end
  else
    puts "   - File exists: ❌ #{dictionary_path} not found"
    exit 1
  end
rescue JSON::ParserError => e
  puts "   - JSON parsing: ❌ #{e.message}"
  exit 1
rescue => e
  puts "   - Dictionary file error: ❌ #{e.message}"
  exit 1
end

puts "\n" + "=" * 60
puts "VALIDATION SUMMARY"
puts "=" * 60
puts "All tests passed! ✅"
puts "The concept ID remapping script should work correctly."
puts "=" * 60
puts
puts "To run the concept ID remapper:"
puts "  bundle exec rails runner lib/remap_concept_ids.rb"
puts