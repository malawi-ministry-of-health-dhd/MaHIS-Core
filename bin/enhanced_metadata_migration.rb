# frozen_string_literal: true

require 'json'
require 'set'

LOGGER = Logger.new($stdout)
User.current = User.first

def usage
  puts 'Usage: rails runner bin/generate_concept_mapping.rb <from> <to> [--dry-run] [--include-concept-sets]'
  puts '  <from> - The source branch/database to get concepts from'
  puts '  <to> - The target branch/database to map concepts to'
  puts '  --dry-run - Preview the mapping without creating actual concepts'
  puts '  --include-concept-sets - Include concept sets in migration (default: exclude)'
  exit
end

from = ARGV[0]
to = ARGV[1]
dry_run = ARGV.include?('--dry-run')
include_concept_sets = ARGV.include?('--include-concept-sets')

usage unless from && to

default_db_config = Rails.configuration.database_configuration['development']
concepts_db_config = Rails.configuration.database_configuration['hts_metadata']

unless default_db_config && concepts_db_config
  LOGGER.error('Could not find database configurations')
  exit
end

# Helper method to check if a concept is a concept set
def is_concept_set?(class_id)
  concept_set_class = ConceptClass.find_by(name: 'ConceptSet') || ConceptClass.find_by(name: 'Concept Set')
  concept_set_class&.id == class_id
end

# Helper method to get concept set members
def get_concept_set_members(concept_id, database_config)
  ConceptName.connection.select_all(format("
    SELECT cs.concept_set, cs.concept_id as member_concept_id, cn.name as member_name
    FROM %<database>s.concept_set cs
    INNER JOIN %<database>s.concept_name cn ON cn.concept_id = cs.concept_id
    INNER JOIN %<database>s.concept c ON c.concept_id = cs.concept_id
    WHERE cs.concept_set = %<concept_id>s
      AND c.retired = 0 AND cn.voided = 0
    ORDER BY cs.sort_weight, cn.name
  ", database: database_config['database'], concept_id: concept_id)).to_a
end

# Helper method to create or update concept set relationships
def manage_concept_set_relationships(concept_set_id, members, target_mapping, dry_run)
  return if dry_run
  
  # Clear existing relationships
  ConceptSet.where(concept_set: concept_set_id).destroy_all
  
  members.each_with_index do |member, index|
    source_member_id = member['member_concept_id']
    
    # Find the target concept ID for this member
    target_member_id = nil
    
    # Check in existing concepts mapping
    if target_mapping[:existing_concepts][source_member_id.to_s]
      target_member_id = target_mapping[:existing_concepts][source_member_id.to_s][:target_id]
    # Check in missing concepts mapping
    elsif target_mapping[:missing_concepts][source_member_id.to_s]
      target_member_id = target_mapping[:missing_concepts][source_member_id.to_s][:target_id]
    # If not in mapping, member might already be synchronized
    else
      target_member_id = source_member_id
    end
    
    next if target_member_id == "ERROR"
    
    begin
      ConceptSet.create!(
        concept_set: concept_set_id,
        concept_id: target_member_id,
        sort_weight: index + 1,
        creator: User.current.id,
        date_created: Time.current
      )
      LOGGER.info("Added concept #{target_member_id} (#{member['member_name']}) to concept set #{concept_set_id}")
    rescue StandardError => e
      LOGGER.error("Failed to add concept #{target_member_id} to concept set #{concept_set_id}: #{e.message}")
    end
  end
end

# Get duplicate concept names
duplicate_names = ConceptName.connection.select_all(format("
  SELECT DISTINCT cn1.name
  FROM %<database_a>s.concept_name cn1
  INNER JOIN %<database_a>s.concept c1 ON c1.concept_id = cn1.concept_id
  WHERE c1.retired = 0 AND cn1.voided = 0
    AND cn1.name IN (
      SELECT cn2.name
      FROM %<database_b>s.concept_name cn2
      INNER JOIN %<database_b>s.concept c2 ON c2.concept_id = cn2.concept_id
      WHERE c2.retired = 0 AND cn2.voided = 0
    )
    AND (
      (SELECT COUNT(*) FROM %<database_a>s.concept_name cn3 
       INNER JOIN %<database_a>s.concept c3 ON c3.concept_id = cn3.concept_id
       WHERE cn3.name = cn1.name AND c3.retired = 0 AND cn3.voided = 0) > 1
      OR
      (SELECT COUNT(*) FROM %<database_b>s.concept_name cn4
       INNER JOIN %<database_b>s.concept c4 ON c4.concept_id = cn4.concept_id
       WHERE cn4.name = cn1.name AND c4.retired = 0 AND cn4.voided = 0) > 1
    )
", database_a: default_db_config['database'], database_b: concepts_db_config['database'])).map { |row| row['name'] }

# Get missing concepts
missing_concepts = ConceptName.connection.select_all(format("
  SELECT cn.name, cn.concept_id, c.creator, c.class_id, c.datatype_id
  FROM %<database_b>s.concept_name cn
  INNER JOIN %<database_b>s.concept c ON c.concept_id = cn.concept_id
  WHERE cn.name NOT IN (SELECT name FROM %<database_a>s.concept_name)
    AND c.retired = 0 AND cn.voided = 0
", database_a: default_db_config['database'], database_b: concepts_db_config['database'])).to_a

# Get all concept IDs that exist in both databases with same name and same ID
synchronized_concept_ids = ConceptName.connection.select_all(format("
  SELECT source_cn.concept_id
  FROM %<database_b>s.concept_name source_cn
  INNER JOIN %<database_b>s.concept source_c ON source_c.concept_id = source_cn.concept_id
  INNER JOIN %<database_a>s.concept_name target_cn ON target_cn.name = source_cn.name AND target_cn.concept_id = source_cn.concept_id
  INNER JOIN %<database_a>s.concept target_c ON target_c.concept_id = target_cn.concept_id
  WHERE source_c.retired = 0 AND source_cn.voided = 0
    AND target_c.retired = 0 AND target_cn.voided = 0
", database_a: default_db_config['database'], database_b: concepts_db_config['database'])).map { |row| row['concept_id'] }

# Get concepts with different IDs (excluding duplicates and synchronized concepts)
all_different_id_concepts = ConceptName.connection.select_all(format("
  SELECT source_cn.name, source_cn.concept_id as source_concept_id, 
         source_c.class_id as source_class_id, target_cn.concept_id as target_concept_id
  FROM %<database_b>s.concept_name source_cn
  INNER JOIN %<database_b>s.concept source_c ON source_c.concept_id = source_cn.concept_id
  INNER JOIN %<database_a>s.concept_name target_cn ON target_cn.name = source_cn.name
  INNER JOIN %<database_a>s.concept target_c ON target_c.concept_id = target_cn.concept_id
  WHERE source_cn.concept_id != target_cn.concept_id
    AND source_c.retired = 0 AND source_cn.voided = 0
    AND target_c.retired = 0 AND target_cn.voided = 0
", database_a: default_db_config['database'], database_b: concepts_db_config['database'])).to_a.reject do |record| 
  duplicate_names.include?(record['name']) || synchronized_concept_ids.include?(record['source_concept_id'])
end

# Remove circular mappings (A->B and B->A)
concepts_with_different_ids = []
circular_pairs = Set.new

all_different_id_concepts.each do |record|
  source_id = record['source_concept_id']
  target_id = record['target_concept_id']
  pair_key = [source_id, target_id].sort.join('-')
  reverse_pair_key = [target_id, source_id].sort.join('-')
  
  # Check if reverse mapping exists
  reverse_exists = all_different_id_concepts.any? do |r|
    r['source_concept_id'] == target_id && r['target_concept_id'] == source_id
  end
  
  if reverse_exists
    circular_pairs.add(pair_key)
  else
    concepts_with_different_ids << record
  end
end

# Separate concept sets from regular concepts
if include_concept_sets
  # Process all concepts including concept sets
  regular_missing_concepts = missing_concepts
  regular_different_id_concepts = concepts_with_different_ids
  
  # Separate concept sets for special handling
  concept_set_missing = missing_concepts.select { |record| is_concept_set?(record['class_id']) }
  concept_set_different_ids = concepts_with_different_ids.select { |record| is_concept_set?(record['source_class_id']) }
  
  LOGGER.info("Including concept sets: #{concept_set_missing.count} missing concept sets, #{concept_set_different_ids.count} concept sets with different IDs")
else
  # Filter out concept sets (original behavior)
  regular_missing_concepts = missing_concepts.reject { |record| is_concept_set?(record['class_id']) }
  regular_different_id_concepts = concepts_with_different_ids.reject { |record| is_concept_set?(record['source_class_id']) }
  
  concept_set_missing = []
  concept_set_different_ids = []
end

LOGGER.info("Processing #{regular_missing_concepts.count} missing concepts and #{regular_different_id_concepts.count} concepts with different IDs (#{circular_pairs.size} circular pairs skipped, #{synchronized_concept_ids.size} synchronized concepts skipped)")

# Initialize mapping objects
existing_concepts_mapping = {}
missing_concepts_mapping = {}
concept_sets_info = {}

if dry_run
  # Process concepts with different IDs
  regular_different_id_concepts.each do |record|
    existing_concepts_mapping[record['source_concept_id'].to_s] = {
      target_id: record['target_concept_id'],
      concept_name: record['name'],
      is_concept_set: is_concept_set?(record['source_class_id'])
    }
  end
  
  # Process missing concepts with placeholder IDs
  regular_missing_concepts.each_with_index do |record, index|
    missing_concepts_mapping[record['concept_id'].to_s] = {
      target_id: 9000 + index,
      concept_name: record['name'],
      is_concept_set: is_concept_set?(record['class_id'])
    }
  end
  
  LOGGER.info("DRY RUN: Would map #{existing_concepts_mapping.keys.count + missing_concepts_mapping.keys.count} concepts")
else
  # Process existing concepts with different IDs
  regular_different_id_concepts.each do |record|
    existing_concepts_mapping[record['source_concept_id'].to_s] = {
      target_id: record['target_concept_id'],
      concept_name: record['name'],
      is_concept_set: is_concept_set?(record['source_class_id'])
    }
  end
  
  # Create missing concepts
  regular_missing_concepts.each do |record|
    begin
      new_concept = Concept.create!(
        short_name: record['name'],
        creator: record['creator'],
        class_id: record['class_id'],
        datatype_id: record['datatype_id']
      )
      
      ConceptName.create!(
        concept_id: new_concept.id,
        name: new_concept.short_name,
        creator: record['creator']
      )
      
      missing_concepts_mapping[record['concept_id'].to_s] = {
        target_id: new_concept.id,
        concept_name: record['name'],
        is_concept_set: is_concept_set?(record['class_id'])
      }
      
    rescue StandardError => e
      LOGGER.error("Failed to create concept #{record['name']}: #{e.message}")
      missing_concepts_mapping[record['concept_id'].to_s] = {
        target_id: "ERROR",
        concept_name: record['name'],
        error: e.message
      }
    end
  end
  
  LOGGER.info("Created mappings for #{existing_concepts_mapping.keys.count + missing_concepts_mapping.keys.count} concepts")
end

# Handle concept sets relationships if included
if include_concept_sets && !dry_run
  # Get all concept sets that need relationship updates
  all_concept_sets = []
  
  # Add concept sets from existing mappings
  existing_concepts_mapping.each do |source_id, mapping|
    if mapping[:is_concept_set]
      all_concept_sets << { source_id: source_id.to_i, target_id: mapping[:target_id], name: mapping[:concept_name] }
    end
  end
  
  # Add concept sets from missing mappings
  missing_concepts_mapping.each do |source_id, mapping|
    if mapping[:is_concept_set] && mapping[:target_id] != "ERROR"
      all_concept_sets << { source_id: source_id.to_i, target_id: mapping[:target_id], name: mapping[:concept_name] }
    end
  end
  
  # Update concept set relationships
  all_concept_sets.each do |concept_set|
    source_members = get_concept_set_members(concept_set[:source_id], concepts_db_config)
    
    if source_members.any?
      LOGGER.info("Updating concept set relationships for '#{concept_set[:name]}' (#{concept_set[:source_id]} -> #{concept_set[:target_id]})")
      
      target_mapping = {
        existing_concepts: existing_concepts_mapping,
        missing_concepts: missing_concepts_mapping
      }
      
      manage_concept_set_relationships(concept_set[:target_id], source_members, target_mapping, dry_run)
      
      concept_sets_info[concept_set[:source_id].to_s] = {
        target_id: concept_set[:target_id],
        name: concept_set[:name],
        members_count: source_members.count,
        members: source_members.map { |m| { source_id: m['member_concept_id'], name: m['member_name'] } }
      }
    else
      LOGGER.warn("No members found for concept set '#{concept_set[:name]}' (#{concept_set[:source_id]})")
    end
  end
end

# Exit if no mappings needed
if existing_concepts_mapping.empty? && missing_concepts_mapping.empty?
  LOGGER.info("No concept mappings needed")
  exit
end

# Create final mapping structure
final_mapping = {
  existing_concepts: existing_concepts_mapping,
  missing_concepts: missing_concepts_mapping,
  concept_sets: concept_sets_info,
  metadata: {
    include_concept_sets: include_concept_sets,
    concept_sets_processed: concept_sets_info.keys.count,
    total_mappings: existing_concepts_mapping.keys.count + missing_concepts_mapping.keys.count,
    circular_pairs_skipped: circular_pairs.size,
    synchronized_concepts_skipped: synchronized_concept_ids.size
  }
}

# Generate and write JSON file
json_filename = "#{Rails.root}/log/concept_mapping-#{from}_to_#{to}-#{DateTime.now.strftime('%Y%m%d%H%M%S')}#{dry_run ? '-DRY_RUN' : ''}#{include_concept_sets ? '-WITH_CONCEPT_SETS' : ''}.json"

File.open(json_filename, 'w') do |file|
  file.write(JSON.pretty_generate(final_mapping))
end

LOGGER.info("Mapping file created: #{json_filename}")
LOGGER.info("Total mappings: #{existing_concepts_mapping.keys.count + missing_concepts_mapping.keys.count}")
LOGGER.info("Concept sets processed: #{concept_sets_info.keys.count}") if include_concept_sets