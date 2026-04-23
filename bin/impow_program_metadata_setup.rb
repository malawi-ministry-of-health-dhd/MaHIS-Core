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

def create_concept_name(concept, name, locale: 'en')

  ConceptName.create!(
    concept_id: concept.id,
    name: name,
    locale: locale,
    locale_preferred: true,
    concept_name_type: 'FULLY_SPECIFIED',
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

  puts 'Creating IMPOW program...'
  program_name = 'IMPOW PROGRAM'

  program_concept_name = ConceptName.find_by_name(program_name)
  User.current = User.find_by_username('admin') || User.first

  # return if program_concept_name.present?
  
  ActiveRecord::Base.transaction do

    program_concept = Concept.find_by_short_name(program_name)
    program_concept ||= create_concept(program_name)

    create_concept_name(program_concept, program_name) unless program_concept_name.present?
    create_program(program_name, program_concept)

    puts "Created program: #{program_name}"
  end
end

run_create_program