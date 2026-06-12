#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../config/environment'
require 'json'

puts "=" * 80
puts "Generating Concept ID Mapping File"
puts "=" * 80

# Get source and destination databases
database_config = Psych.load(File.read('config/database.yml'), aliases: true).freeze
source_db = database_config['centralized_source_db']['database']

puts "\nStep 1: Fetching all concepts from source database..."
# Use FULLY_SPECIFIED names only to avoid SHORT/SYNONYM name collisions during mapping.
# For concepts without a FULLY_SPECIFIED name, fall back to any non-voided english name.
source_concepts = ActiveRecord::Base.connection.select_all(
  "SELECT concept_id,
          COALESCE(
            MAX(CASE WHEN concept_name_type = 'FULLY_SPECIFIED' THEN name END),
            MAX(name)
          ) AS name
   FROM #{source_db}.concept_name
   WHERE locale = 'en'
   AND voided = 0
   GROUP BY concept_id"
).to_a

puts "✓ Found #{source_concepts.size} concepts in source"

puts "\nStep 2: Fetching all concepts from destination database..."
dest_concepts = ActiveRecord::Base.connection.select_all(
  "SELECT concept_id,
          COALESCE(
            MAX(CASE WHEN concept_name_type = 'FULLY_SPECIFIED' THEN name END),
            MAX(name)
          ) AS name
   FROM concept_name
   WHERE locale = 'en'
   AND voided = 0
   GROUP BY concept_id"
).to_a

puts "✓ Found #{dest_concepts.size} concepts in destination"

puts "\nStep 3: Building name-to-ID map for destination..."
# Build a map of lowercase FULLY_SPECIFIED name => destination concept_id.
# Later entries overwrite earlier ones, so FULLY_SPECIFIED names win over fallbacks.
dest_name_map = dest_concepts.each_with_object({}) do |row, hash|
  key = row['name'].downcase.strip
  hash[key] = row['concept_id']
end

puts "✓ Built index for #{dest_name_map.size} unique concept names"

puts "\nStep 4: Mapping source concepts to destination concepts..."
concept_mapping = {}
matched_count = 0
unmatched_concepts = []

source_concepts.each do |source_concept|
  source_id = source_concept['concept_id']
  source_name = source_concept['name'].downcase.strip
  
  if dest_name_map[source_name]
    concept_mapping[source_id] = dest_name_map[source_name]
    matched_count += 1
  else
    unmatched_concepts << { id: source_id, name: source_concept['name'] }
  end
end

puts "✓ Matched #{matched_count} concepts"
puts "✗ #{unmatched_concepts.size} concepts not found in destination"

if unmatched_concepts.size > 0 && unmatched_concepts.size < 50
  puts "\nUnmatched concepts:"
  unmatched_concepts.first(20).each do |c|
    puts "  - ID #{c[:id]}: #{c[:name]}"
  end
  puts "  ... and #{unmatched_concepts.size - 20} more" if unmatched_concepts.size > 20
end

puts "\nStep 5: Saving mapping to file..."
mapping_file = Rails.root.join('db', 'concept_id_mapping.json')
File.write(mapping_file, JSON.pretty_generate({
  generated_at: Time.now.iso8601,
  source_database: source_db,
  total_source_concepts: source_concepts.size,
  total_dest_concepts: dest_concepts.size,
  matched_concepts: matched_count,
  unmatched_concepts: unmatched_concepts.size,
  mapping: concept_mapping
}))

puts "✓ Mapping saved to: #{mapping_file}"

puts "\n" + "=" * 80
puts "Mapping completed!"
puts "  - Total source concepts: #{source_concepts.size}"
puts "  - Matched: #{matched_count} (#{(matched_count.to_f / source_concepts.size * 100).round(2)}%)"
puts "  - Unmatched: #{unmatched_concepts.size}"
puts "=" * 80
