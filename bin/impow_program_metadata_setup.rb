# frozen_string_literal: true

 

def create_concept(concept_name, datatype_id: 4, concept_class_id: 11, is_set: false)
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

  Program.create!(
    name: program_name,
    description: 'Integrated Management and Prevention of Oedema and Wasting',
    concept_id: concept.id,
    creator: User.current.id,
    date_created: Time.now
  )

end

 

def run_create_program
  puts 'Creating IMPOW program and related concepts...'
  User.current = User.find_by_username('admin') || User.first

  concepts_to_create = [
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
    },
    {
      program_name: 'Community',
      concept_names: [
        { value: 'Community', type: 'FULLY_SPECIFIED' },
        { value: 'Community', type: 'SHORT' }
      ]
    }
  ]

  ActiveRecord::Base.transaction do
    concepts_to_create.each do |concept_info|
      program_name = concept_info[:program_name]
      program_concept = Concept.find_by_short_name(program_name)
      program_concept ||= create_concept(program_name)

      concept_info[:concept_names].each do |name|
        exists = ConceptName.where(concept_id: program_concept.id, name: name[:value], concept_name_type: name[:type]).exists?
        create_concept_name(program_concept, name[:value], type: name[:type]) unless exists
      end

      # Only create a program for IMPOW PROGRAM
      if program_name == 'IMPOW PROGRAM'
        create_program(program_name, program_concept)
        puts "Created program: #{program_name}"
      else
        puts "Created concept: #{program_name}"
      end
    end
  end
end

run_create_program