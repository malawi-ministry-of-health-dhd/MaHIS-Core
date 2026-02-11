#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to create Laboratory Program, Order Types, and Concepts from Excel file
# Usage: bin/rails runner bin/create_lab_metadata.rb

require 'roo'

class LabMetadataCreator
  def initialize(file_path)
    @xlsx = Roo::Spreadsheet.open(file_path)
    @created_concepts = []
    @updated_concepts = []
    @created_order_types = []
    @created_programs = []
    @errors = []
  end

  def run
    puts 'Starting Lab Metadata Creation...'
    puts '=' * 80

    ActiveRecord::Base.transaction do
      create_concepts
      create_order_types
      create_programs

      if @errors.any?
        puts "\n❌ Errors occurred:"
        @errors.each { |error| puts "  - #{error}" }
        raise ActiveRecord::Rollback
      end
    end

    print_summary
  end

  private

  def create_concepts
    puts "\n📝 Creating Concepts..."
    sheet = @xlsx.sheet('Lims concepts')

    sheet.each_with_index do |row, index|
      next if index.zero? # Skip header

      concept_id, name, locale, concept_name_type, datatype, concept_class, = row

      next if name.blank?

      begin
        # Check if concept already exists by name (using binary comparison)
        existing_concept_name = ConceptName.where('BINARY name = ?', name)
                                           .where(locale: locale || 'en')
                                           .first

        if existing_concept_name
          existing_concept = Concept.find(existing_concept_name.concept_id)
          puts "  ✓ Concept already exists: #{name} (ID: #{existing_concept.concept_id})"
          @updated_concepts << name
        else
          # Create new concept
          concept = create_concept(concept_id, datatype, concept_class)
          create_concept_name(concept.concept_id, name, locale, concept_name_type)
          @created_concepts << name
          puts "  ✓ Created concept: #{name} (ID: #{concept.concept_id})"
        end
      rescue StandardError => e
        error_msg = "Failed to create concept '#{name}': #{e.message}"
        @errors << error_msg
        puts "  ✗ #{error_msg}"
      end
    end
  end

  def create_concept(concept_id, datatype_name, class_name)
    # Use binary comparison to avoid collation issues
    datatype = ConceptDatatype.where('BINARY name = ?', datatype_name).first ||
               ConceptDatatype.where('BINARY name = ?', 'N/A').first
    concept_class = ConceptClass.where('BINARY name = ?', class_name).first ||
                    ConceptClass.where('BINARY name = ?', 'Misc').first

    concept = Concept.new
    concept.concept_id = concept_id if concept_id.present?
    concept.datatype_id = datatype.concept_datatype_id
    concept.concept_class = concept_class
    concept.retired = false
    concept.is_set = (%w[ConvSet LabSet].include?(class_name))
    concept.creator = User.current.id
    concept.date_created = Time.current
    concept.save!
    concept
  end

  def create_concept_name(concept_id, name, locale, name_type)
    locale ||= 'en'
    name_type = nil if name_type == 'NULL'

    # Find existing concept name using binary comparison to avoid collation issues
    concept_name = ConceptName.where(concept_id: concept_id, locale: locale)
                              .where('BINARY name = ?', name)
                              .first_or_initialize do |cn|
      cn.name = name
      cn.concept_id = concept_id
      cn.locale = locale
    end

    concept_name.concept_name_type = name_type
    concept_name.creator = User.current.id
    concept_name.date_created = Time.current unless concept_name.persisted?
    concept_name.voided = false
    concept_name.save!
    concept_name
  end

  def create_order_types
    puts "\n📋 Creating Order Types..."
    sheet = @xlsx.sheet('Lims Order types')

    sheet.each_with_index do |row, index|
      next if index.zero? # Skip header

      name, description = row
      next if name.blank?

      begin
        # Use binary comparison to avoid collation issues
        order_type = OrderType.where('BINARY name = ?', name).first_or_initialize do |ot|
          ot.name = name
        end

        if order_type.persisted?
          puts "  ✓ Order type already exists: #{name}"
        else
          order_type.description = description
          order_type.creator = User.current.id
          order_type.date_created = Time.current
          order_type.retired = false
          order_type.save!
          @created_order_types << name
          puts "  ✓ Created order type: #{name}"
        end
      rescue StandardError => e
        error_msg = "Failed to create order type '#{name}': #{e.message}"
        @errors << error_msg
        puts "  ✗ #{error_msg}"
      end
    end
  end

  def create_programs
    puts "\n🏥 Creating Programs..."
    sheet = @xlsx.sheet('Laboratory Program')

    sheet.each_with_index do |row, index|
      next if index.zero? # Skip header

      name = row[0]
      next if name.blank?

      begin
        # Use binary comparison to avoid collation issues
        program = Program.where('BINARY name = ?', name).first_or_initialize do |p|
          p.name = name
        end

        if program.persisted?
          puts "  ✓ Program already exists: #{name}"
        else
          concept = create_program_concept(name)
          program.concept_id = concept.concept_id
          program.creator = User.current.id
          program.date_created = Time.current
          program.retired = false
          program.save!
          @created_programs << name
          puts "  ✓ Created program: #{name}"
        end
      rescue StandardError => e
        error_msg = "Failed to create program '#{name}': #{e.message}"
        @errors << error_msg
        puts "  ✗ #{error_msg}"
      end
    end
  end

  def create_program_concept(program_name)
    # Check if concept already exists using binary comparison
    concept_name = ConceptName.where('BINARY name = ?', program_name).first
    return Concept.find(concept_name.concept_id) if concept_name

    # Create new concept for program
    concept = create_concept(nil, 'N/A', 'Program')
    create_concept_name(concept.concept_id, program_name, 'en', 'FULLY_SPECIFIED')
    concept
  end

  def print_summary
    puts "\n" + '=' * 80
    puts '📊 Summary'
    puts '=' * 80
    puts "Concepts created: #{@created_concepts.count}"
    @created_concepts.each { |name| puts "  - #{name}" }

    puts "\nConcepts updated: #{@updated_concepts.count}"
    @updated_concepts.each { |name| puts "  - #{name}" }

    puts "\nOrder types created: #{@created_order_types.count}"
    @created_order_types.each { |name| puts "  - #{name}" }

    puts "\nPrograms created: #{@created_programs.count}"
    @created_programs.each { |name| puts "  - #{name}" }

    if @errors.any?
      puts "\n❌ Errors: #{@errors.count}"
      puts 'Transaction rolled back - no changes were made.'
    else
      puts "\n✅ All metadata created successfully!"
    end
    puts '=' * 80
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME || caller.any? { |c| c.include?('rails/commands/runner') }
  file_path = ARGV[0] || Rails.root.join('db', 'data', 'csv', 'Lims concepts.xlsx').to_s

  unless File.exist?(file_path)
    puts "❌ Error: File not found: #{file_path}"
    puts 'Usage: bin/rails runner bin/create_lab_metadata.rb [path_to_excel_file]'
    exit 1
  end

  begin
    # Set current user to avoid location_id filtering issues
    User.current = User.unscoped.first || User.unscoped.last

    creator = LabMetadataCreator.new(file_path)
    creator.run
  rescue StandardError => e
    puts "\n❌ Fatal error: #{e.message}"
    puts e.backtrace.join("\n")
    exit 1
  end
end
