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
end

run_create_program
