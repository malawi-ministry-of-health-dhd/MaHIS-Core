#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# IMPOW Drug CMS Seeder Script
# ============================================================
# Seeds drugs from IMPOW program concept sets into drug_cms table
# 
# Program Assignment:
#   - SFS (Supplementary Feeding Services) → OS Program
#   - OTS (Outpatient Therapeutic Services) → OS Program  
#   - ITS (Inpatient Therapeutic Service) → ITS Program
#
# Usage:
#   ruby bin/seed_impow_drug_cms.rb
#   OR
#   rails runner bin/seed_impow_drug_cms.rb
# ============================================================

class ImpowDrugCmsSeeder
  attr_reader :stats

  def initialize
    @stats = {
      total_processed: 0,
      successful: 0,
      failed: 0,
      skipped: 0,
      errors: []
    }
  end

  def seed!
    puts "=" * 80
    puts "IMPOW Drug CMS Seeder"
    puts "=" * 80
    puts "\nStarting at: #{Time.current}"
    puts "\nFinding programs..."
    
    os_program = find_or_report_missing_program('OS Program')
    its_program = find_or_report_missing_program('ITS Program')
    
    return unless os_program && its_program
    
    puts "\n✓ Found OS Program (ID: #{os_program.program_id})"
    puts "✓ Found ITS Program (ID: #{its_program.program_id})"
    
    # Seed drugs from each concept set
    seed_concept_set('Supplementary Feeding Services', os_program, 'SFS')
    seed_concept_set('Outpatient Therapeutic Services', os_program, 'OTS')
    seed_concept_set('Inpatient Therapeutic Service', its_program, 'ITS')
    
    print_summary
  end

  private

  def find_or_report_missing_program(program_name)
    program = Program.find_by(name: program_name)
    
    unless program
      puts "\n✗ ERROR: '#{program_name}' not found in database!"
      puts "  Please create this program first or update the script with the correct program name."
      return nil
    end
    
    program
  end

  def seed_concept_set(concept_set_name, program, section_name)
    puts "\n#{'-' * 80}"
    puts "Seeding #{section_name}: #{concept_set_name}"
    puts "Program: #{program.name} (ID: #{program.program_id})"
    puts '-' * 80
    
    drugs = Drug.find_all_by_concept_set(concept_set_name)
    
    if drugs.empty?
      puts "⚠ No drugs found for concept set: #{concept_set_name}"
      return
    end
    
    puts "Found #{drugs.count} drugs"
    
    drugs.each_with_index do |drug, index|
      @stats[:total_processed] += 1
      
      print "\n[#{index + 1}/#{drugs.count}] Processing: #{drug.name} (Drug ID: #{drug.drug_id})... "
      
      begin
        result = create_or_update_drug_cms(drug, program)
        
        if result[:action] == :created
          puts "✓ CREATED"
          @stats[:successful] += 1
        elsif result[:action] == :updated
          puts "✓ UPDATED"
          @stats[:successful] += 1
        elsif result[:action] == :skipped
          puts "⊘ SKIPPED (#{result[:reason]})"
          @stats[:skipped] += 1
        end
      rescue StandardError => e
        puts "✗ FAILED"
        @stats[:failed] += 1
        @stats[:errors] << {
          drug_id: drug.drug_id,
          drug_name: drug.name,
          error: e.message,
          backtrace: e.backtrace.first(3)
        }
        puts "  Error: #{e.message}"
      end
    end
  end

  def create_or_update_drug_cms(drug, program)
    # Check if drug_cms already exists for this drug and program
    existing = DrugCms.unscoped.find_by(
      drug_inventory_id: drug.drug_id,
      program_id: program.program_id
    )
    
    drug_cms_params = build_drug_cms_params(drug, program)
    
    if existing
      # Update existing record
      if existing.voided == 1
        # Unvoid and update
        existing.update!(drug_cms_params.merge(voided: 0, voided_by: nil, date_voided: nil, void_reason: nil))
        { action: :updated, record: existing }
      else
        # Already exists and not voided
        { action: :skipped, reason: 'already exists' }
      end
    else
      # Create new record
      drug_cms = DrugCms.create!(drug_cms_params)
      { action: :created, record: drug_cms }
    end
  end

  def build_drug_cms_params(drug, program)
    {
      drug_inventory_id: drug.drug_id,
      name: drug.name,
      short_name: drug.name,  # Use drug name directly as short_name
      code: generate_code(drug),
      pack_size: extract_pack_size(drug.name),
      strength: extract_strength(drug.name),
      tabs: extract_tabs(drug.name),
      weight: extract_weight(drug.name),
      program_id: program.program_id,
      location_id: nil  # Can be set if needed
    }
  end

  # Extract short name from drug name
  # e.g., "Amoxicillin (250mg dispersible tablet)" -> "Amox 250mg"
  def extract_short_name(drug_name)
    # Try to get the base name and strength
    base_name = drug_name.split('(').first.strip
    strength = extract_strength(drug_name)
    
    # Shorten common long names
    base_name = shorten_name(base_name)
    
    if strength
      "#{base_name} #{strength}".truncate(50)
    else
      base_name.truncate(50)
    end
  end

  # Shorten common long drug names
  def shorten_name(name)
    shortenings = {
      'Amoxicillin' => 'Amox',
      'Ready-to-Use Therapeutic Food' => 'RUTF',
      'Ready-to-Use Supplementary Food' => 'RUSF',
      'Corn Soy Blend Plus Plus' => 'CSB++',
      'Corn Soy Blend Plus' => 'CSB+',
      'Therapeutic Milk' => 'TM',
      'Albendazole' => 'Albend',
      'Mebendazole' => 'Mebend',
      'Vitamin A' => 'Vit A',
      'Ferrous sulphate' => 'FeSO4',
      'Potassium Permanganate' => 'KMnO4',
      'Tetracycline' => 'Tetra',
      'Atropine sulphate' => 'Atropine'
    }
    
    shortenings.each do |long, short|
      return name.gsub(long, short) if name.include?(long)
    end
    
    name
  end

  # Generate a unique code for the drug
  def generate_code(drug)
    base_code = drug.name.split('(').first.strip
                    .upcase
                    .gsub(/[^A-Z0-9]/, '')
                    .truncate(8, omission: '')
    
    # Add drug_id to ensure uniqueness
    "#{base_code}#{drug.drug_id}"
  end

  # Extract pack size from drug name or default to 1
  def extract_pack_size(drug_name)
    # Look for patterns like "1000 tablets", "100 sachets", etc.
    match = drug_name.match(/(\d+)\s*(tablets?|sachets?|capsules?|vials?|bottles?)/i)
    return match[1].to_i if match
    
    # Default pack size
    1
  end

  # Extract strength from drug name
  # e.g., "Amoxicillin (250mg tablet)" -> "250mg"
  def extract_strength(drug_name)
    match = drug_name.match(/\((\d+\s*(?:mg|g|mcg|iu|IU|%)).*?\)/i)
    match ? match[1] : nil
  end

  # Extract tabs/units from drug name
  def extract_tabs(drug_name)
    # Look for patterns in parentheses that might indicate unit count
    match = drug_name.match(/\(.*?(\d+)\s*(?:tablets?|tabs?|capsules?|caps?)\)/i)
    match ? match[1] : nil
  end

  # Extract weight from drug name (for some drugs)
  def extract_weight(drug_name)
    # Extract numeric weight if present
    match = drug_name.match(/(\d+(?:\.\d+)?)\s*(?:kg|g)/i)
    match ? match[1].to_f : nil
  end

  def print_summary
    puts "\n#{'=' * 80}"
    puts "SEEDING COMPLETE"
    puts '=' * 80
    puts "\nCompleted at: #{Time.current}"
    puts "\nStatistics:"
    puts "  Total Processed: #{@stats[:total_processed]}"
    puts "  ✓ Successful:    #{@stats[:successful]} (Created/Updated)"
    puts "  ⊘ Skipped:       #{@stats[:skipped]} (Already exists)"
    puts "  ✗ Failed:        #{@stats[:failed]}"
    
    if @stats[:errors].any?
      puts "\nErrors encountered:"
      @stats[:errors].each_with_index do |error, index|
        puts "\n  #{index + 1}. Drug: #{error[:drug_name]} (ID: #{error[:drug_id]})"
        puts "     Error: #{error[:error]}"
        puts "     Location: #{error[:backtrace].join("\n              ")}"
      end
    end
    
    puts "\n#{'=' * 80}\n"
  end
end

# Run the seeder
if __FILE__ == $PROGRAM_NAME || caller.any? { |line| line.include?('rails/commands/runner') }
  begin
    seeder = ImpowDrugCmsSeeder.new
    seeder.seed!
  rescue StandardError => e
    puts "\n✗ FATAL ERROR: #{e.message}"
    puts e.backtrace.join("\n")
    exit 1
  end
end
