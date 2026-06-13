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

puts "\nStep 1: Fetching all concept names from source database..."
# Fetch every non-voided English name per concept so we can try all synonyms during
# matching. FULLY_SPECIFIED names are sorted first so they are tried first.
source_concept_name_rows = ActiveRecord::Base.connection.select_all(
  "SELECT concept_id, name, concept_name_type
   FROM #{source_db}.concept_name
   WHERE locale = 'en'
   AND voided = 0
   ORDER BY concept_id,
            CASE concept_name_type WHEN 'FULLY_SPECIFIED' THEN 0 ELSE 1 END"
).to_a

# Group into { concept_id => [rows...] } — FULLY_SPECIFIED rows appear first in each group.
source_concepts = source_concept_name_rows.group_by { |r| r['concept_id'] }

puts "✓ Found #{source_concepts.size} concepts (#{source_concept_name_rows.size} names total) in source"

puts "\nStep 2: Fetching all concept names from destination database..."
# Index every synonym so any source name can match, not just whichever one happened
# to sort highest. FULLY_SPECIFIED names are sorted first so they win on collisions.
dest_concept_name_rows = ActiveRecord::Base.connection.select_all(
  "SELECT concept_id, name
   FROM concept_name
   WHERE locale = 'en'
   AND voided = 0
   ORDER BY CASE concept_name_type WHEN 'FULLY_SPECIFIED' THEN 0 ELSE 1 END"
).to_a

dest_concept_count = dest_concept_name_rows.map { |r| r['concept_id'] }.uniq.size
puts "✓ Found #{dest_concept_count} concepts (#{dest_concept_name_rows.size} names total) in destination"

puts "\nStep 3: Building name-to-ID map for destination (all synonyms indexed)..."
# Map every name (including synonyms) to its concept_id. Using ||= means the first
# entry for a given name wins; because rows are sorted FULLY_SPECIFIED-first, the
# canonical name takes precedence when two concepts share a synonym.
dest_name_map = dest_concept_name_rows.each_with_object({}) do |row, hash|
  key = row['name'].downcase.gsub(/\s+/, ' ').strip
  hash[key] ||= row['concept_id']
end

puts "✓ Indexed #{dest_name_map.size} unique names across #{dest_concept_count} concepts"

puts "\nStep 4: Mapping source concepts to destination concepts..."
concept_mapping = {}
matched_count = 0
unmatched_concepts = []

source_concepts.each do |source_id, name_rows|
  # Try each name in order (FULLY_SPECIFIED first) until one matches the destination.
  matching_row = name_rows.find { |r| dest_name_map[r['name'].downcase.gsub(/\s+/, ' ').strip] }

  if matching_row
    concept_mapping[source_id] = dest_name_map[matching_row['name'].downcase.gsub(/\s+/, ' ').strip]
    matched_count += 1
  else
    unmatched_concepts << { id: source_id, name: name_rows.first['name'] }
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
  total_dest_concepts: dest_concept_count,
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
