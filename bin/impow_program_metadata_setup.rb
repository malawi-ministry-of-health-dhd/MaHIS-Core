# frozen_string_literal: true

require 'securerandom'

CONCEPTS_TO_CREATE = [
    {
      program_name: 'IMPOW PROGRAM',
      concept_names: [
        { value: 'IMPOW PROGRAM', type: 'FULLY_SPECIFIED' }
      ]
    },
    {
      program_name: 'Outpatient Therapeutic Services',
      concept_names: [
        { value: 'Outpatient Therapeutic Services', type: 'FULLY_SPECIFIED' },
        { value: 'OTS', type: 'SHORT' }
      ]
    },
    {
      program_name: 'Supplementary Feeding Services',
      concept_names: [
        { value: 'Supplementary Feeding Services', type: 'FULLY_SPECIFIED' },
        { value: 'SFS', type: 'SHORT' }
      ]
    },
    {
      program_name: 'Inpatient Therapeutic Service',
      concept_names: [
        { value: 'Inpatient Therapeutic Service', type: 'FULLY_SPECIFIED' },
        { value: 'ITS', type: 'SHORT' }
      ]
    }
  ]

ENCOUNTER_TYPES_TO_CREATE = [
  { name: 'Triage', description: '' },
  { name: 'Medical Assessment', description: '' }
]


def create_concept(concept_name, datatype_id: 4, concept_class_id: 11, is_set: false)

  existing_concept = Concept.find_by(short_name: concept_name)
  if existing_concept
    puts "Skipped concept: #{concept_name} (already exists)"
    return existing_concept
  end

  Concept.create!(
    short_name: concept_name,
    datatype_id: datatype_id,
    class_id: concept_class_id,
    is_set: is_set,
    creator: User.current.id,
    date_created: Time.now
  )

end

def create_concept_name(concept, name, type: 'FULLY_SPECIFIED', locale: 'en')
  existing = ConceptName.find_by(concept_id: concept.id, name: name, concept_name_type: type)
  if existing
    puts "Skipped concept name: #{name} (#{type}) (already exists)"
    return existing
  end
  ConceptName.create!(
    concept_id: concept.id,
    name: name,
    locale: locale,
    locale_preferred: true,
    concept_name_type: type,
    creator: User.current.id,
    date_created: Time.now
  )
end


def create_program(program_name, concept)
  existing_program = Program.find_by(name: program_name)
  if existing_program
    puts "Skipped program: #{program_name} (already exists)"
    return existing_program
  end
  Program.create!(
    name: program_name,
    description: 'Integrated Management and Prevention of Oedema and Wasting',
    concept_id: concept.id,
    creator: User.current.id,
    date_created: Time.now
  )
end

def create_encounter_type(name, description = nil)
  existing = EncounterType.find_by(name: name)
  if existing
    puts "Skipped encounter type: #{name} (already exists)"
    return existing
  end
  EncounterType.create!(
    name: name,
    description: description,
    creator: User.current.id,
    date_created: Time.now,
    retired: 0,
    uuid: SecureRandom.uuid
  )
end

def create_drug_concept_set(set_name, short_name = nil)
  # Create the concept set as a concept (ConvSet class, N/A datatype)
  set_concept = create_concept(set_name, datatype_id: 4, concept_class_id: 10, is_set: true)

  # Create concept names
  exists = ConceptName.where(concept_id: set_concept.id, name: set_name,
                             concept_name_type: 'FULLY_SPECIFIED').exists?
  create_concept_name(set_concept, set_name, type: 'FULLY_SPECIFIED') unless exists

  if short_name
    short_exists = ConceptName.where(concept_id: set_concept.id, name: short_name,
                                     concept_name_type: 'SHORT').exists?
    create_concept_name(set_concept, short_name, type: 'SHORT') unless short_exists
  end

  set_concept
end

def get_dosage_form_concept(dosage_form_name)
  # Find existing dosage form concept
  dosage_form_concept = Concept.joins(:concept_names)
                               .where(concept_names: { name: dosage_form_name })
                               .first

  unless dosage_form_concept
    # Create dosage form if it doesn't exist
    dosage_form_concept = create_concept(dosage_form_name, datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: dosage_form_concept.id, name: dosage_form_name,
                               concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(dosage_form_concept, dosage_form_name, type: 'FULLY_SPECIFIED') unless exists
  end

  dosage_form_concept
end

def create_drug_and_link_to_set(drug_name, set_concept, sort_weight = 1, dosage_form_name = 'Sachet')
  # Create drug concept (Drug class, N/A datatype)
  drug_concept = create_concept(drug_name, datatype_id: 4, concept_class_id: 3, is_set: false)

  # Create concept name if not exists
  exists = ConceptName.where(concept_id: drug_concept.id, name: drug_name,
                             concept_name_type: 'FULLY_SPECIFIED').exists?
  create_concept_name(drug_concept, drug_name, type: 'FULLY_SPECIFIED') unless exists

  # Get dosage form concept
  dosage_form_concept = get_dosage_form_concept(dosage_form_name)

  # Create drug record in drug table
  drug = Drug.find_by(concept_id: drug_concept.concept_id)
  if drug
    puts "  Drug already exists: #{drug_name}"
  else
    drug = Drug.create!(
      concept_id: drug_concept.concept_id,
      name: drug_name,
      combination: 0,
      dosage_form: dosage_form_concept.concept_id,
      creator: User.current.id,
      date_created: Time.now,
      retired: 0,
      uuid: SecureRandom.uuid
    )
    puts "  Created drug: #{drug_name} (Form: #{dosage_form_name})"
  end

  # Link drug concept to concept set
  concept_set_link = ConceptSet.find_by(
    concept_set: set_concept.concept_id,
    concept_id: drug_concept.concept_id
  )

  unless concept_set_link
    ConceptSet.create!(
      concept_set: set_concept.concept_id,
      concept_id: drug_concept.concept_id,
      sort_weight: sort_weight,
      creator: User.current.id,
      date_created: Time.now,
      uuid: SecureRandom.uuid
    )
    puts "    Linked '#{drug_name}' to concept set"
  end

  drug
end

def create_nutrition_drugs
  puts "\n" + '=' * 80
  puts 'Creating IMPOW Nutrition Drugs and Concept Sets...'
  puts '=' * 80

  ActiveRecord::Base.transaction do
    # 1. SFP (Supplementary Feeding Services) Drugs
    puts "\n1. Creating SFP Drug Concept Set..."
    sfp_set = create_drug_concept_set('Supplementary Feeding Services', 'SFP')

    # RUSF comes in sachets, CSB+ and CSB++ are powders
    create_drug_and_link_to_set('Ready-to-Use Supplementary Food (RUSF)', sfp_set, 1, 'Sachet')
    create_drug_and_link_to_set('Corn Soy Blend Plus (CSB+)', sfp_set, 2, 'Powder')
    create_drug_and_link_to_set('Corn Soy Blend Plus Plus (CSB++)', sfp_set, 3, 'Powder')

    # 2. OTP (Outpatient Therapeutic Services) Drugs
    puts "\n2. Creating OTP Drug Concept Set..."
    otp_set = create_drug_concept_set('Outpatient Therapeutic Services', 'OTP')

    # RUTF comes in sachets
    create_drug_and_link_to_set('Ready-to-Use Therapeutic Food (RUTF)', otp_set, 1, 'Sachet')

    # 3. NRU (Inpatient Therapeutic Service) Drugs
    puts "\n3. Creating NRU Drug Concept Set..."
    nru_set = create_drug_concept_set('Inpatient Therapeutic Service', 'NRU')

    # F-75 and F-100 are powders, RUTF is sachet
    create_drug_and_link_to_set('F-75 Therapeutic Milk (F75)', nru_set, 1, 'Powder')
    create_drug_and_link_to_set('F-100 Therapeutic Milk (F100)', nru_set, 2, 'Powder')
    create_drug_and_link_to_set('Ready-to-Use Therapeutic Food (RUTF)', nru_set, 3, 'Sachet')

    puts "\n" + '=' * 80
    puts 'Successfully created all IMPOW nutrition drugs and concept sets!'
    puts '=' * 80
  end
end

def run_create_program
  puts 'Creating IMPOW program and related concepts...'
  User.current = User.find_by_username('admin') || User.first

  ActiveRecord::Base.transaction do
    CONCEPTS_TO_CREATE.each do |concept_info|
      program_name = concept_info[:program_name]
      program_concept = Concept.find_by_short_name(program_name)
      if program_concept
        puts "Skipped concept: #{program_name} (already exists)"
      else
        program_concept = create_concept(program_name)
        puts "Created concept: #{program_name}"
      end

      concept_info[:concept_names].each do |name|
        exists = ConceptName.where(concept_id: program_concept.id, name: name[:value],
                                   concept_name_type: name[:type]).exists?
        create_concept_name(program_concept, name[:value], type: name[:type]) unless exists
      end

      # Only create a program for IMPOW PROGRAM
      if program_name == 'IMPOW PROGRAM'
        program = Program.find_by(name: program_name)
        if program
          puts "Skipped program: #{program_name} (already exists)"
        else
          create_program(program_name, program_concept)
          puts "Created program: #{program_name}"
        end
      end
    end

    ENCOUNTER_TYPES_TO_CREATE.each do |encounter_type|
      existing = EncounterType.find_by(name: encounter_type[:name])
      if existing
        puts "Skipped encounter type: #{encounter_type[:name]} (already exists)"
      else
        create_encounter_type(encounter_type[:name], encounter_type[:description])
        puts "Created encounter type: #{encounter_type[:name]}"
      end
    end
  end
  create_nutrition_drugs
end

run_create_program
