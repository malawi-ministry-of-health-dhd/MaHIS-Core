# frozen_string_literal: true

require 'securerandom'

CONCEPTS_TO_CREATE = [
  {
    program_name: 'OTS PROGRAM',
    concept_names: [
      { value: 'OTS PROGRAM', type: 'FULLY_SPECIFIED' }
    ]
  },
  {
    program_name: 'NRU PROGRAM',
    concept_names: [
      { value: 'NRU PROGRAM', type: 'FULLY_SPECIFIED' }
    ]
  },
  {
    program_name: 'ICCM/CMAM PROGRAM',
    concept_names: [
      { value: 'ICCM/CMAM PROGRAM', type: 'FULLY_SPECIFIED' }
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
  { name: 'Medical Assessment', description: '' },
  { name: 'OTS Admission', description: 'Encounter type for admission to Outpatient Therapeutic Services'},
]

def create_concept(concept_name, datatype_id: 4, concept_class_id: 11, is_set: false)
  existing_concept = Concept.find_by(concept_id: ConceptName.find_by(name: concept_name)&.concept_id)
  existing_concept ||= Concept.find_by(short_name: concept_name)
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

def get_route_concept(route_name)
  # Find existing route concept
  route_concept = Concept.joins(:concept_names)
                         .where(concept_names: { name: route_name })
                         .first

  unless route_concept
    # Create route if it doesn't exist
    route_concept = create_concept(route_name, datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: route_concept.id, name: route_name,
                               concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(route_concept, route_name, type: 'FULLY_SPECIFIED') unless exists
  end

  route_concept
end

def create_drug_and_link_to_set(drug_name, set_concept, sort_weight = 1, dosage_form_name = 'Sachet',
                                route_name = 'Oral', units = 'g', concept_name = nil)
  # Use drug_name as concept_name if not provided separately
  concept_name ||= drug_name

  # Create drug concept (Drug class, N/A datatype)
  drug_concept = create_concept(concept_name, datatype_id: 4, concept_class_id: 3, is_set: false)

  # Create concept name if not exists
  exists = ConceptName.where(concept_id: drug_concept.id, name: concept_name,
                             concept_name_type: 'FULLY_SPECIFIED').exists?
  create_concept_name(drug_concept, concept_name, type: 'FULLY_SPECIFIED') unless exists

  # Get dosage form and route concepts
  dosage_form_concept = get_dosage_form_concept(dosage_form_name)
  route_concept = get_route_concept(route_name)

  # Create drug record in drug table with specific drug_name
  drug = Drug.find_by(concept_id: drug_concept.concept_id, name: drug_name)
  if drug
    puts "  Drug already exists: #{drug_name}"
  else
    drug = Drug.create!(
      concept_id: drug_concept.concept_id,
      name: drug_name,
      combination: 0,
      dosage_form: dosage_form_concept.concept_id,
      route: route_concept.concept_id,
      units: units,
      creator: User.current.id,
      date_created: Time.now,
      retired: 0,
      uuid: SecureRandom.uuid
    )
    puts "  Created drug: #{drug_name} (Concept: #{concept_name}, Form: #{dosage_form_name}, Route: #{route_name}, Units: #{units})"
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

def link_existing_drugs_to_set(concept_name, set_concept, start_sort_weight = 1)
  # Find the concept by name
  concept = Concept.joins(:concept_names)
                   .where(concept_names: { name: concept_name })
                   .first

  unless concept
    puts "  WARNING: Concept '#{concept_name}' not found. Skipping."
    return []
  end

  # Find all drugs with this concept_id
  drugs = Drug.where(concept_id: concept.concept_id)

  if drugs.empty?
    puts "  No drugs found for concept '#{concept_name}'. Skipping."
    return []
  end

  puts "  Found #{drugs.count} drug(s) for concept '#{concept_name}'"

  # Link each drug's concept to the set
  drugs.each_with_index do |drug, index|
    concept_set_link = ConceptSet.find_by(
      concept_set: set_concept.concept_id,
      concept_id: drug.concept_id
    )

    if concept_set_link
      puts "    Drug '#{drug.name}' already linked to set"
    else
      ConceptSet.create!(
        concept_set: set_concept.concept_id,
        concept_id: drug.concept_id,
        sort_weight: start_sort_weight + index,
        creator: User.current.id,
        date_created: Time.now,
        uuid: SecureRandom.uuid
      )
      puts "    Linked drug '#{drug.name}' to set"
    end
  end

  drugs
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
    create_drug_and_link_to_set('Ready-to-Use Therapeutic Food (RUTF)', otp_set, 1, 'Sachet', 'Oral', 'Sachets')

    # Create specific Amoxicillin 1000mg tablet
    puts "\n  Creating Amoxicillin 1000mg tablet..."
    create_drug_and_link_to_set('Amoxicillin (1000mg tablet)', otp_set, 2, 'Tablet', 'Oral', 'tabs', 'Amoxicillin')

    # Create specific Amoxicillin 750mg tablet
    puts "\n  Creating Amoxicillin 750mg tablet..."
    create_drug_and_link_to_set('Amoxicillin (750mg tablet)', otp_set, 3, 'Tablet', 'Oral', 'tabs', 'Amoxicillin')

    # Create specific Ampicillin 125mg tablet
    puts "\n  Creating Ampicillin 125mg tablet..."
    create_drug_and_link_to_set('Ampicillin (125mg tablet)', otp_set, 4, 'Tablet', 'Oral', 'tabs', 'Ampicillin')

    # Create specific Ampicillin 250mg tablet
    puts "\n  Creating Ampicillin 250mg tablet..."
    create_drug_and_link_to_set('Ampicillin (250mg tablet)', otp_set, 5, 'Tablet', 'Oral', 'tabs', 'Ampicillin')

    # Create specific Ampicillin 500mg tablet
    puts "\n  Creating Ampicillin 500mg tablet..."
    create_drug_and_link_to_set('Ampicillin (500mg tablet)', otp_set, 6, 'Tablet', 'Oral', 'tabs', 'Ampicillin')

    # Create specific Ampicillin 750mg tablet
    puts "\n  Creating Ampicillin 750mg tablet..."
    create_drug_and_link_to_set('Ampicillin (750mg tablet)', otp_set, 7, 'Tablet', 'Oral', 'tabs', 'Ampicillin')

    # Create specific Ampicillin 1000mg tablet
    puts "\n  Creating Ampicillin 1000mg tablet..."
    create_drug_and_link_to_set('Ampicillin (1000mg tablet)', otp_set, 8, 'Tablet', 'Oral', 'tabs', 'Ampicillin')

    # Link existing Amoxicillin drugs to OTP set
    puts "\n  Linking existing Amoxicillin drugs to OTP..."
    link_existing_drugs_to_set('Amoxicillin', otp_set, 10)

    # Link existing Ampicillin drugs to OTP set
    puts "\n  Linking existing Ampicillin drugs to OTP..."
    link_existing_drugs_to_set('Ampicillin', otp_set, 10)

    # Link existing Albendazole drugs to OTP set
    puts "\n  Linking existing Albendazole drugs to OTP..."
    link_existing_drugs_to_set('Albendazole', otp_set, 10)

    # Link existing Mebendazole drugs to OTP set
    puts "\n  Linking existing Mebendazole drugs to OTP..."
    link_existing_drugs_to_set('Mebendazole', otp_set, 20)

    # Link existing Vitamin A drugs to OTP set
    puts "\n  Linking existing Vitamin A drugs to OTP..."
    link_existing_drugs_to_set('Vitamin A', otp_set, 30)

    # 3. NRU (Inpatient Therapeutic Service) Drugs
    puts "\n3. Creating NRU Drug Concept Set..."
    nru_set = create_drug_concept_set('Inpatient Therapeutic Service', 'NRU')

    # F-75 and F-100 share the same "Therapeutic Milk" concept but are different drugs
    create_drug_and_link_to_set('F-75 Therapeutic Milk (F75)', nru_set, 1, 'Powder', 'Oral', 'g', 'Therapeutic Milk')
    create_drug_and_link_to_set('F-100 Therapeutic Milk (F100)', nru_set, 2, 'Powder', 'Oral', 'g', 'Therapeutic Milk')
    create_drug_and_link_to_set('Ready-to-Use Therapeutic Food (RUTF)', nru_set, 3, 'Sachet', 'Oral', 'Sachets')

    # Create malaria drugs and link to OTS and NRU sets
    ['DP 60mg/480mg', 'DP 80mg/640mg', 'DP 20mg/160mg', 'DP 30mg/240mg', 'DP 40mg/320mg', 'Rectal Artesunate', 'LA (Lumefantrine + arthemether)'].each_with_index do |drug_name, index|
      puts "\n  Creating #{drug_name} and linking to OTS and NRU..."
      create_drug_and_link_to_set(drug_name, otp_set, 10 + index, 'Tablet', 'Oral', 'tabs', drug_name)
      create_drug_and_link_to_set(drug_name, nru_set, 10 + index, 'Tablet', 'Oral', 'tabs', drug_name)
    end

    # Create vaccination drugs and link to OTS set
    ['BCG', 'Measles vaccine', 'ROTA Vaccination', 'PCV', 'Pentavalent Vaccination'].each_with_index do |vaccine_name, index|
      puts "\n  Creating #{vaccine_name} and linking to OTS..."
      create_drug_and_link_to_set(vaccine_name, otp_set, 20 + index, 'Vaccine', 'Intramuscular (IM)', 'doses', vaccine_name)
    end
    ['Polio Vaccination'].each_with_index do |vaccine_name, index|
      puts "\n  Creating #{vaccine_name} and linking to OTS..."
      create_drug_and_link_to_set(vaccine_name, otp_set, 25 + index, 'Vaccine', 'Oral', 'doses', vaccine_name)
    end

    puts "\n" + '=' * 80
    puts 'Successfully created all IMPOW nutrition drugs and concept sets!'
    puts '=' * 80
  end
end

# Create a coded concept with multiple choice answers
# @param concept_name [String] The name of the concept
# @param concept_class_name [String] The concept class (e.g., 'Procedure', 'Finding')
# @param answers [Array<String>] Array of answer names (e.g., ['Yes', 'No'])
# @return [Concept] The created concept or nil if error
def create_coded_concept_with_answers(concept_name, concept_class_name, _answers = [])
  # Find or create the concept class and datatype
  concept_class = ConceptClass.find_by(name: concept_class_name)
  concept_datatype = ConceptDatatype.find_by(name: 'Coded')

  unless concept_class && concept_datatype
    puts "  ERROR: Could not find ConceptClass '#{concept_class_name}' or ConceptDatatype 'Coded'"
    return nil
  end

  # Check if concept already exists
  existing_concept = Concept.joins(:concept_names).where(concept_names: { name: concept_name }).first
  if existing_concept
    puts "  Skipped concept: #{concept_name} (already exists)"
    return existing_concept
  end

  # Create the concept
  concept = Concept.create!(
    short_name: concept_name,
    datatype_id: concept_datatype.concept_datatype_id,
    class_id: concept_class.concept_class_id,
    is_set: false,
    creator: User.current.id,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )

  # Create concept name
  ConceptName.create!(
    concept_id: concept.concept_id,
    name: concept_name,
    locale: 'en',
    locale_preferred: true,
    concept_name_type: 'FULLY_SPECIFIED',
    creator: User.current.id,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )

  puts "  Created coded concept: #{concept_name} (#{concept_class_name})"

  concept
end

# Create a numeric concept with optional units
# @param concept_name [String] The name of the concept
# @param concept_class_name [String] The concept class (e.g., 'Finding', 'Test')
# @param units [String] The units for numeric values (e.g., 'days', 'kg', 'cm')
# @param allow_decimal [Boolean] Whether to allow decimal values
# @return [Concept] The created concept or nil if error
def create_numeric_concept(concept_name, concept_class_name, units = nil, allow_decimal: false)
  # Find or create the concept class and datatype
  concept_class = ConceptClass.find_by(name: concept_class_name)
  concept_datatype = ConceptDatatype.find_by(name: 'Numeric')

  unless concept_class && concept_datatype
    puts "  ERROR: Could not find ConceptClass '#{concept_class_name}' or ConceptDatatype 'Numeric'"
    return nil
  end

  # Check if concept already exists
  existing_concept = Concept.joins(:concept_names).where(concept_names: { name: concept_name }).first
  if existing_concept
    puts "  Skipped concept: #{concept_name} (already exists)"
    return existing_concept
  end

  # Create the concept
  concept = Concept.create!(
    short_name: concept_name,
    datatype_id: concept_datatype.concept_datatype_id,
    class_id: concept_class.concept_class_id,
    is_set: false,
    creator: User.current.id,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )

  # Create concept name
  ConceptName.create!(
    concept_id: concept.concept_id,
    name: concept_name,
    locale: 'en',
    locale_preferred: true,
    concept_name_type: 'FULLY_SPECIFIED',
    creator: User.current.id,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )

  # Create concept numeric entry if units are specified
  unless units
    puts "  Created numeric concept: #{concept_name} (#{concept_class_name})"
    return concept
  end

  ConceptNumeric.create!(
    concept_id: concept.concept_id,
    hi_absolute: nil,
    hi_critical: nil,
    hi_normal: nil,
    low_absolute: nil,
    low_critical: nil,
    low_normal: nil,
    units: units,
    precise: allow_decimal ? 1 : 0
  )
  puts "  Created numeric concept: #{concept_name} (#{concept_class_name}, units: #{units})"

  concept
end

# Create a text concept
# @param concept_name [String] The name of the concept
# @param concept_class_name [String] The concept class (e.g., 'Finding', 'Misc')
# @return [Concept] The created concept or nil if error
def create_text_concept(concept_name, concept_class_name)
  # Find or create the concept class and datatype
  concept_class = ConceptClass.find_by(name: concept_class_name)
  concept_datatype = ConceptDatatype.find_by(name: 'Text')

  unless concept_class && concept_datatype
    puts "  ERROR: Could not find ConceptClass '#{concept_class_name}' or ConceptDatatype 'Text'"
    return nil
  end

  # Check if concept already exists
  existing_concept = Concept.joins(:concept_names).where(concept_names: { name: concept_name }).first
  if existing_concept
    puts "  Skipped concept: #{concept_name} (already exists)"
    return existing_concept
  end

  # Create the concept
  concept = Concept.create!(
    short_name: concept_name,
    datatype_id: concept_datatype.concept_datatype_id,
    class_id: concept_class.concept_class_id,
    is_set: false,
    creator: User.current.id,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )

  # Create concept name
  ConceptName.create!(
    concept_id: concept.concept_id,
    name: concept_name,
    locale: 'en',
    locale_preferred: true,
    concept_name_type: 'FULLY_SPECIFIED',
    creator: User.current.id,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )

  puts "  Created text concept: #{concept_name} (#{concept_class_name})"

  concept
end

# Create IMPOW nutrition-related concepts
# This creates:
# - Pentavalent Vaccination (Coded, Procedure) with Yes/No answers
# - Days in NRU (Numeric, Finding) with days as units
def create_nutrition_concepts
  puts "\n" + '=' * 80
  puts 'Creating IMPOW Nutrition Concepts...'
  puts '=' * 80

  ActiveRecord::Base.transaction do
    # Create Pentavalent Vaccination concept (Coded, Procedure)
    puts "\n1. Creating Pentavalent Vaccination concept..."
    create_coded_concept_with_answers('Pentavalent Vaccination', 'Procedure', %w[Yes No])

    # Create Days in NRU concept (Numeric, Finding)
    puts "\n2. Creating Days in NRU concept..."
    create_numeric_concept('Days in NRU', 'Finding', 'days', allow_decimal: false)

    # Create Cold hands concept (Coded, Finding)
    puts "\n3. Creating Cold hands concept..."
    create_coded_concept_with_answers('Cold hands', 'Finding', %w[Yes No])

    # Create Radial Pulse concept (Coded, Finding)
    puts "\n4. Creating Radial Pulse concept..."
    create_coded_concept_with_answers('Radial Pulse', 'Finding', %w[No Yes])

    # Create Eye Appearance concept (Coded, Finding)
    puts "\n5. Creating Eye Appearance concept..."
    create_coded_concept_with_answers('Eye Appearance', 'Finding', %w[Normal Sunken Discharge])

    # Create Ear Condition concept (Coded, Finding)
    puts "\n6. Creating Ear Condition concept..."
    create_coded_concept_with_answers('Ear Condition', 'Finding', %w[Normal Discharge])

    # Create Skin Integrity concept (Coded, Finding)
    puts "\n7. Creating Skin Integrity concept..."
    create_coded_concept_with_answers('Skin Integrity', 'Finding', ['Healthy', 'Ulcers/Abscesses', 'Raw', 'Peeling'])

    # Create Lymph Nodes Swelling concept (Coded, Finding)
    puts "\n8. Creating Lymph Nodes Swelling concept..."
    create_coded_concept_with_answers('Lymph Nodes Swelling', 'Finding', %w[Normal Groin Neck])

    # Create Unsuitable Home Circumstances concept (Boolean, Finding)
    puts "\n9. Creating Unsuitable Home Circumstances concept..."
    create_coded_concept_with_answers('Unsuitable Home Circumstances', 'Finding', %w[Yes No])

    # Create Appetite concept (Coded, Finding)
    puts "\n10. Creating Appetite concept..."
    create_coded_concept_with_answers('Appetite', 'Finding', %w[Good Poor None])

    # Create Family TB History concept (Coded, Finding)
    puts "\n11. Creating Family TB History concept..."
    create_coded_concept_with_answers('Family TB History', 'Finding', %w[No Yes])

    # Create Stools per Day concept (Coded, Finding)
    puts "\n12. Creating Stools per Day concept..."
    create_coded_concept_with_answers('Stools per Day', 'Finding', ['1-3', '4-5', '>5'])

    # Create Polio Vaccination concept (Coded, Procedure)
    puts "\n13. Creating Polio Vaccination concept..."
    create_coded_concept_with_answers('Polio Vaccination', 'Procedure', %w[Yes No])

    # Create ROTA Vaccination concept (Coded, Procedure)
    puts "\n14. Creating ROTA Vaccination concept..."
    create_coded_concept_with_answers('ROTA Vaccination', 'Procedure', %w[Yes No])

    # Create Duration of swelling concept (Text, Finding)
    puts "\n15. Creating Duration of swelling concept..."
    create_text_concept('Duration of swelling', 'Finding')

    # Create Appetite test concept (Coded, Test)
    puts "\n16. Creating Appetite test concept..."
    create_coded_concept_with_answers('Appetite test', 'Test', [])

    # Create Fail concept (Misc, N/A)
    puts "\n17. Creating Fail concept..."
    fail_concept = create_concept('Fail', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: fail_concept.id, name: 'Fail', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(fail_concept, 'Fail', type: 'FULLY_SPECIFIED') unless exists

    # Create Groin concept (Misc, N/A)
    puts "\n18. Creating Groin concept..."
    groin_concept = create_concept('Groin', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: groin_concept.id, name: 'Groin', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(groin_concept, 'Groin', type: 'FULLY_SPECIFIED') unless exists

    # Create Pass concept (Misc, N/A)
    puts "\n19. Creating Pass concept..."
    pass_concept = create_concept('Pass', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: pass_concept.id, name: 'Pass', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(pass_concept, 'Pass', type: 'FULLY_SPECIFIED') unless exists

    # Create Raw concept (Misc, N/A)
    puts "\n20. Creating Raw concept..."
    raw_concept = create_concept('Raw', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: raw_concept.id, name: 'Raw', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(raw_concept, 'Raw', type: 'FULLY_SPECIFIED') unless exists

    # Create Sore concept (Misc, N/A)
    puts "\n21. Creating Sore concept..."
    sore_concept = create_concept('Sore', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: sore_concept.id, name: 'Sore', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(sore_concept, 'Sore', type: 'FULLY_SPECIFIED') unless exists

    # Create Ulcers/Abscesses concept (Misc, N/A)
    puts "\n22. Creating Ulcers/Abscesses concept..."
    ulcers_concept = create_concept('Ulcers/Abscesses', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: ulcers_concept.id, name: 'Ulcers/Abscesses', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(ulcers_concept, 'Ulcers/Abscesses', type: 'FULLY_SPECIFIED') unless exists

    # Create Cured concept (Text, Finding)
    puts "\n23. Creating Cured concept..."
    create_text_concept('Cured', 'Finding')

    # Create Feet concept (Misc, N/A)
    puts "\n24. Creating Feet concept..."
    feet_concept = create_concept('Feet', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: feet_concept.id, name: 'Feet', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(feet_concept, 'Feet', type: 'FULLY_SPECIFIED') unless exists

    # Create Exposed concept (Misc, N/A)
    puts "\n25. Creating Exposed concept..."
    exposed_concept = create_concept('Exposed', datatype_id: 4, concept_class_id: 11, is_set: false)
    exists = ConceptName.where(concept_id: exposed_concept.id, name: 'Exposed', concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(exposed_concept, 'Exposed', type: 'FULLY_SPECIFIED') unless exists

    puts "\n" + '=' * 80
    puts 'Successfully created nutrition concepts!'
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

      # Only create a program for ICCM PROGRAM, OTS PROGRAM, and NRU PROGRAM concepts
      next unless ['ICCM/CMAM PROGRAM', 'OTS PROGRAM', 'NRU PROGRAM'].include?(program_name)

      program = Program.find_by(name: program_name)
      if program_name == 'OTS PROGRAM'
        program ||= Program.find_by(name: 'IMPOW Program')
        program&.update(name: program_name) if program && program.name != program_name
      end
      if program
        puts "Skipped program: #{program_name} (already exists)"
      else
        create_program(program_name, program_concept)
        puts "Created program: #{program_name}"
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
  create_nutrition_concepts
  create_nutrition_drugs
end

run_create_program
