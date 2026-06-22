# frozen_string_literal: true

require 'securerandom'

CONCEPTS_TO_CREATE = [
  {
    program_name: 'OTS/SFP PROGRAM',
    concept_names: [
      { value: 'OTS/SFP PROGRAM', type: 'FULLY_SPECIFIED' }
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
  { name: 'OTS Admission', description: 'Encounter type for admission to Outpatient Therapeutic Services' },
  { name: 'Initial Assessment', description: 'Encounter type for initial assessment in NRU' }
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
    ['DP 60mg/480mg', 'DP 80mg/640mg', 'DP 20mg/160mg', 'DP 30mg/240mg', 'DP 40mg/320mg', 'Rectal Artesunate',
     'LA (Lumefantrine + arthemether)'].each_with_index do |drug_name, index|
      puts "\n  Creating #{drug_name} and linking to OTS and NRU..."
      create_drug_and_link_to_set(drug_name, otp_set, 10 + index, 'Tablet', 'Oral', 'tabs', drug_name)
      create_drug_and_link_to_set(drug_name, nru_set, 10 + index, 'Tablet', 'Oral', 'tabs', drug_name)
    end

    # Create vaccination drugs and link to OTS set
    ['BCG', 'Measles vaccine', 'ROTA Vaccination', 'PCV',
     'Pentavalent Vaccination'].each_with_index do |vaccine_name, index|
      puts "\n  Creating #{vaccine_name} and linking to OTS..."
      create_drug_and_link_to_set(vaccine_name, otp_set, 20 + index, 'Vaccine', 'Intramuscular (IM)', 'doses',
                                  vaccine_name)
    end
    ['Polio Vaccination'].each_with_index do |vaccine_name, index|
      puts "\n  Creating #{vaccine_name} and linking to OTS..."
      create_drug_and_link_to_set(vaccine_name, otp_set, 25 + index, 'Vaccine', 'Oral', 'doses', vaccine_name)
    end

    # 4. Antibiotics Drug Concept Set
    puts "\n4. Creating Antibiotics Drug Concept Set..."
    antibiotics_set = create_drug_concept_set('Antibiotics', 'Antibiotics')

    # Create antibiotic drugs
    antibiotics = [
      { name: 'Amoxicillin', form: 'Tablet', route: 'Oral', units: 'tabs' },
      { name: 'Ampicillin', form: 'Tablet', route: 'Oral', units: 'tabs' },
      { name: 'BenzylPenicillin', form: 'Injection', route: 'Intramuscular (IM)', units: 'vials' },
      { name: 'Ceftriaxone', form: 'Injection', route: 'Intramuscular (IM)', units: 'vials' },
      { name: 'Cefotaxime', form: 'Injection', route: 'Intramuscular (IM)', units: 'vials' },
      { name: 'Ciprofloxacin', form: 'Tablet', route: 'Oral', units: 'tabs' },
      { name: 'Cloxacillin', form: 'Tablet', route: 'Oral', units: 'tabs' },
      { name: 'Gentamicin', form: 'Injection', route: 'Intramuscular (IM)', units: 'vials' },
      { name: 'Metronidazole', form: 'Tablet', route: 'Oral', units: 'tabs' }
    ]

    antibiotics.each_with_index do |antibiotic, index|
      puts "\n  Creating #{antibiotic[:name]}..."
      create_drug_and_link_to_set(
        antibiotic[:name],
        antibiotics_set,
        index + 1,
        antibiotic[:form],
        antibiotic[:route],
        antibiotic[:units],
        antibiotic[:name]
      )
    end

    # 5. Antifungal Drug Concept Set
    puts "\n5. Creating Antifungal Drug Concept Set..."
    antifungal_set = create_drug_concept_set('Antifungal', 'Antifungal')

    # Create antifungal drugs
    puts "\n  Creating Fluconazole..."
    create_drug_and_link_to_set('Fluconazole', antifungal_set, 1, 'Tablet', 'Oral', 'tabs', 'Fluconazole')

    # 6. Antiseptic Drug Concept Set
    puts "\n6. Creating Antiseptic Drug Concept Set..."
    antiseptic_set = create_drug_concept_set('Antiseptic', 'Antiseptic')

    # Create antiseptic drugs
    puts "\n  Creating Potassium Permanganate..."
    create_drug_and_link_to_set('Potassium Permanganate(1% KMnO4)', antiseptic_set, 1, 'Solution', 'Topical', 'ml',
                                'Potassium Permanganate medicinal')
    Drug.find_by(name: 'Ferrous sulphate')&.update(concept_id: ConceptName.find_by(name: 'Ferrous sulfate')&.concept_id, dosage_form: get_dosage_form_concept('Tablet')&.concept_id, route: get_route_concept('Oral')&.concept_id, units: 'tabs')
    Drug.find_by(name:'Tetracycline eye ointment 1%')&.update(concept_id: ConceptName.find_by(name: 'Tetracycline eye ointment 1%')&.concept_id, dosage_form: get_dosage_form_concept('Ointment')&.concept_id, route: get_route_concept('Topical')&.concept_id, units: 'g')
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

# Create a date concept
# @param concept_name [String] The name of the concept
# @param concept_class_name [String] The concept class (e.g., 'Finding', 'Misc', 'Drug')
# @return [Concept] The created concept or nil if error
def create_date_concept(concept_name, concept_class_name)
  # Find or create the concept class and datatype
  concept_class = ConceptClass.find_by(name: concept_class_name)
  concept_datatype = ConceptDatatype.find_by(name: 'Date')

  unless concept_class && concept_datatype
    puts "  ERROR: Could not find ConceptClass '#{concept_class_name}' or ConceptDatatype 'Date'"
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

  puts "  Created date concept: #{concept_name} (#{concept_class_name})"

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
    exists = ConceptName.where(concept_id: groin_concept.id, name: 'Groin',
                               concept_name_type: 'FULLY_SPECIFIED').exists?
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
    exists = ConceptName.where(concept_id: ulcers_concept.id, name: 'Ulcers/Abscesses',
                               concept_name_type: 'FULLY_SPECIFIED').exists?
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
    exists = ConceptName.where(concept_id: exposed_concept.id, name: 'Exposed',
                               concept_name_type: 'FULLY_SPECIFIED').exists?
    create_concept_name(exposed_concept, 'Exposed', type: 'FULLY_SPECIFIED') unless exists

    # Create Pre-referral / emergency treatment comments concept (Text, Misc)
    puts "\n26. Creating Pre-referral / emergency treatment comments concept..."
    create_text_concept('Pre-referral / emergency treatment comments', 'Misc')

    # Create Severe wasting concept (Coded, Finding)
    puts "\n27. Creating Severe wasting concept..."
    create_coded_concept_with_answers('Severe wasting', 'Finding', %w[Yes No])

    # Create Dermatosis (raw skin / fissures) concept (Coded, Finding)
    puts "\n28. Creating Dermatosis (raw skin / fissures) concept..."
    create_coded_concept_with_answers('Dermatosis (raw skin / fissures)', 'Finding', %w[Yes No])

    # Create Watery diarrhoea concept (Coded, Symptom)
    puts "\n29. Creating Watery diarrhoea concept..."
    create_coded_concept_with_answers('Watery diarrhoea', 'Symptom', %w[Yes No])

    # Create Dry mouth / tongue concept (Coded, Finding)
    puts "\n30. Creating Dry mouth / tongue concept..."
    create_coded_concept_with_answers('Dry mouth / tongue', 'Finding', %w[Yes No])

    # Create Days with diarrhoea concept (Numeric, Finding)
    puts "\n31. Creating Days with diarrhoea concept..."
    create_numeric_concept('Days with diarrhoea', 'Finding', 'days', allow_decimal: false)

    # Create Bitot's spots concept (Coded, Finding)
    puts "\n32. Creating Bitot's spots concept..."
    create_coded_concept_with_answers("Bitot's spots", 'Finding', %w[Yes No])

    # Create Corneal clouding concept (Coded, Finding)
    puts "\n33. Creating Corneal clouding concept..."
    create_coded_concept_with_answers('Corneal clouding', 'Finding', %w[Yes No])

    # Create Eye pus or inflammation concept (Coded, Finding)
    puts "\n34. Creating Eye pus or inflammation concept..."
    create_coded_concept_with_answers('Eye pus or inflammation', 'Finding', %w[Yes No])

    # Create HTS Date concept (Date, Misc)
    puts "\n35. Creating HTS Date concept..."
    create_date_concept('HTS Date', 'Misc')

    # Create Cotrimoxazole Start Date concept (Date, Drug)
    puts "\n36. Creating Cotrimoxazole Start Date concept..."
    create_date_concept('Cotrimoxazole Start Date', 'Drug')

    # Create Unconscious concept (Coded, Finding)
    puts "\n37. Creating Unconscious concept..."
    create_coded_concept_with_answers('Unconscious', 'Finding', %w[Yes No])

    # Create Capillary refill time more than 3 seconds concept (Coded, Finding)
    puts "\n38. Creating Capillary refill time more than 3 seconds concept..."
    create_coded_concept_with_answers('Capillary refill time more than 3 seconds', 'Finding', %w[Yes No])

    # Create Pulse Rate Weak concept (Coded, Finding)
    puts "\n39. Creating Pulse Rate Weak concept..."
    create_coded_concept_with_answers('Pulse Rate Weak', 'Finding', %w[Yes No])

    # Create Oedema concept (Coded, Finding)
    puts "\n40. Creating Oedema concept..."
    create_coded_concept_with_answers('Oedema', 'Finding', %w[Yes No])

    # Create Blood in stool concept (Coded, Symptom)
    puts "\n41. Creating Blood in stool concept..."
    create_coded_concept_with_answers('Blood in stool', 'Symptom', %w[Yes No])

    # Create Vomiting concept (Coded, Symptom)
    puts "\n42. Creating Vomiting concept..."
    create_coded_concept_with_answers('Vomiting', 'Symptom', %w[Yes No])

    # Create Restlessness concept (Coded, Finding)
    puts "\n43. Creating Restlessness concept..."
    create_coded_concept_with_answers('Restlessness', 'Finding', %w[Yes No])

    # Create Sunken eyes concept (Coded, Finding)
    puts "\n44. Creating Sunken eyes concept..."
    create_coded_concept_with_answers('Sunken eyes', 'Finding', %w[Yes No])

    # Create Measles concept (Coded, Diagnosis)
    puts "\n45. Creating Measles concept..."
    create_coded_concept_with_answers('Measles', 'Diagnosis', %w[Yes No])

    # Create Corneal ulcer concept (Coded, Finding)
    puts "\n46. Creating Corneal ulcer concept..."
    create_coded_concept_with_answers('Corneal ulcer', 'Finding', %w[Yes No])

    # Create HTS Outcome concept (Coded, Misc)
    puts "\n47. Creating HTS Outcome concept..."
    create_coded_concept_with_answers('HTS Outcome', 'Misc', ['Positive', 'Negative', 'Not Done'])

    # Create ART start date concept (Date, Drug)
    puts "\n48. Creating ART start date concept..."
    create_date_concept('ART start date', 'Drug')

    # Create Weight concept (Numeric, Finding)
    puts "\n49. Creating Weight concept..."
    create_numeric_concept('Weight', 'Finding', 'kg', allow_decimal: true)

    # Create Height (cm) concept (Numeric, Finding)
    puts "\n50. Creating Height (cm) concept..."
    create_numeric_concept('Height (cm)', 'Finding', 'cm', allow_decimal: true)

    # Create MUAC concept (Numeric, Finding)
    puts "\n51. Creating MUAC concept..."
    create_numeric_concept('MUAC', 'Finding', 'mm', allow_decimal: true)

    # Create Temperature concept (Numeric, Finding)
    puts "\n52. Creating Temperature concept..."
    create_numeric_concept('Temperature', 'Finding', '°C', allow_decimal: true)

    # Create Route of temperature concept (Coded, Finding)
    puts "\n53. Creating Route of temperature concept..."
    create_coded_concept_with_answers('Route of temperature', 'Finding', %w[Oral Rectal Axillary])

    # Create Blood glucose concept (Numeric, Test)
    puts "\n54. Creating Blood glucose concept..."
    create_numeric_concept('Blood glucose', 'Test', 'mg/dL', allow_decimal: true)

    # Create Haemoglobin concept (Numeric, Test)
    puts "\n55. Creating Haemoglobin concept..."
    create_numeric_concept('Haemoglobin', 'Test', 'g/dL', allow_decimal: true)

    # Create Packed cell volume concept (Numeric, Test)
    puts "\n56. Creating Packed cell volume concept..."
    create_numeric_concept('Packed cell volume', 'Test', '%', allow_decimal: true)

    # Create ABO Blood Grouping concept (Coded, Test)
    puts "\n57. Creating ABO Blood Grouping concept..."
    create_coded_concept_with_answers('ABO Blood Grouping', 'Test', %w[A B AB O])

    # Create Diarrhoea episodes (number of loose stools) concept (Numeric, Finding)
    puts "\n58. Creating Diarrhoea episodes (number of loose stools) concept..."
    create_numeric_concept('Diarrhoea episodes (number of loose stools)', 'Finding', nil, allow_decimal: false)

    # Create Vomiting episodes concept (Numeric, Finding)
    puts "\n59. Creating Vomiting episodes concept..."
    create_numeric_concept('Vomiting episodes', 'Finding', nil, allow_decimal: false)

    # Create ReSoMal concept (Coded, Procedure)
    puts "\n60. Creating ReSoMal concept..."
    create_coded_concept_with_answers('ReSoMal volume given', 'Procedure', %w[Yes No])

    # Create Clinical notes construct concept (Text, Misc)
    puts "\n61. Creating Clinical notes construct concept..."
    create_text_concept('Clinical notes construct', 'Misc')

    # Create Breastfeeding concept (Coded, Finding)
    puts "\n62. Creating Breastfeeding concept..."
    create_coded_concept_with_answers('Breastfeeding', 'Finding', %w[Yes No])

    # Create Starting weight for feed plan concept (Numeric, Finding)
    puts "\n63. Creating Starting weight for feed plan concept..."
    create_numeric_concept('Starting weight for feed plan', 'Finding', 'kg', allow_decimal: true)

    # Create Amount of feed offered concept (Numeric, Finding)
    puts "\n64. Creating Amount of feed offered concept..."
    create_numeric_concept('Amount of feed offered', 'Finding', 'ml', allow_decimal: true)

    # Create Amount of feed left concept (Numeric, Finding)
    puts "\n65. Creating Amount of feed left concept..."
    create_numeric_concept('Amount of feed left', 'Finding', 'ml', allow_decimal: true)

    # Create Amount of feed taken orally concept (Numeric, Finding)
    puts "\n66. Creating Amount of feed taken orally concept..."
    create_numeric_concept('Amount of feed taken orally', 'Finding', 'ml', allow_decimal: true)

    # Create Amount of feed given via NG tube concept (Numeric, Finding)
    puts "\n67. Creating Amount of feed given via NG tube concept..."
    create_numeric_concept('Amount of feed given via NG tube', 'Finding', 'ml', allow_decimal: true)

    # Create Estimated amount vomited concept (Numeric, Finding)
    puts "\n68. Creating Estimated amount vomited concept..."
    create_numeric_concept('Estimated amount vomited', 'Finding', 'ml', allow_decimal: true)

    # Create Loose stools after feed concept (Numeric, Finding)
    puts "\n69. Creating Loose stools after feed concept..."
    create_numeric_concept('Loose stools after feed', 'Finding', nil, allow_decimal: false)

    # Create Malaria Rapid Diagnostic Test concept (Coded, Test)
    puts "\n70. Creating Malaria Rapid Diagnostic Test concept..."
    create_coded_concept_with_answers('Malaria Rapid Diagnostic Test', 'Test', %w[Positive Negative])

    # Create Antimalarial concept (Coded, Drug)
    puts "\n71. Creating Antimalarial concept..."
    create_coded_concept_with_answers('Antimalarial', 'Drug', %w[Yes No])

    # Create Vitamin A concept (Coded, Procedure)
    puts "\n72. Creating Vitamin A concept..."
    create_coded_concept_with_answers('Vitamin A', 'Procedure', %w[Yes No])

    # Create Deworming (Albendazole / Mebendazole) given concept (Coded, Procedure)
    puts "\n73. Creating Deworming (Albendazole / Mebendazole) given concept..."
    create_coded_concept_with_answers('Deworming (Albendazole / Mebendazole) given', 'Procedure', %w[Yes No])

    # Create Minerals iron supplements concept (Coded, Drug)
    puts "\n74. Creating Minerals iron supplements concept..."
    create_coded_concept_with_answers('Minerals iron supplements', 'Drug', %w[Yes No])

    # Create Tetracycline eye ointment given concept (Coded, Procedure)
    puts "\n75. Creating Tetracycline eye ointment given concept..."
    create_coded_concept_with_answers('Tetracycline eye ointment given', 'Procedure', %w[Yes No])

    # Create Atropine eye drops given concept (Coded, Procedure)
    puts "\n76. Creating Atropine eye drops given concept..."
    create_coded_concept_with_answers('Atropine eye drops given', 'Procedure', %w[Yes No])

    # Create Dermatosis treatment (1% KMnO₄ / zinc oxide bath) concept (Coded, Procedure)
    puts "\n77. Creating Dermatosis treatment (1% KMnO₄ / zinc oxide bath) concept..."
    create_coded_concept_with_answers('Dermatosis treatment (1% KMnO₄ / zinc oxide bath)', 'Procedure', %w[Yes No])

    # Create Respiratory rate concept (Numeric, Finding)
    puts "\n78. Creating Respiratory rate concept..."
    create_numeric_concept('Respiratory rate', 'Finding', 'breaths/min', allow_decimal: false)

    # Create Pulse Rate concept (Numeric, Finding)
    puts "\n79. Creating Pulse Rate concept..."
    create_numeric_concept('Pulse Rate', 'Finding', 'beats/min', allow_decimal: false)

    # Create Hospitalization discharge date concept (Date, Misc)
    puts "\n80. Creating Hospitalization discharge date concept..."
    create_date_concept('Hospitalization discharge date', 'Misc')

    # Create Cause of death concept (Text, Misc)
    puts "\n81. Creating Cause of death concept..."
    create_text_concept('Cause of death', 'Misc')

    # Create Time Of Death concept (Text, Misc)
    puts "\n82. Creating Time Of Death concept..."
    create_text_concept('Time Of Death', 'Misc')

    # Create IV Fluids given concept (Coded, Procedure)
    puts "\n83. Creating IV Fluids given concept..."
    create_coded_concept_with_answers('IV Fluids given', 'Procedure', %w[Yes No])

    # Create BCG immunization was given at birth? concept (Coded, Procedure)
    puts "\n84. Creating BCG immunization was given at birth? concept..."
    create_coded_concept_with_answers('BCG immunization was given at birth?', 'Procedure', %w[Yes No])

    # Create OPV vaccination given concept (Coded, Procedure)
    puts "\n85. Creating OPV vaccination given concept..."
    create_coded_concept_with_answers('OPV vaccination given', 'Procedure', %w[Yes No])

    # Create Pentavalent vaccination given concept (Coded, Procedure)
    puts "\n86. Creating Pentavalent vaccination given concept..."
    create_coded_concept_with_answers('Pentavalent vaccination given', 'Procedure', %w[Yes No])

    # Create PCV vaccination given concept (Coded, Procedure)
    puts "\n87. Creating PCV vaccination given concept..."
    create_coded_concept_with_answers('PCV vaccination given', 'Procedure', %w[Yes No])

    # Create Rotavirus vaccination given concept (Coded, Procedure)
    puts "\n88. Creating Rotavirus vaccination given concept..."
    create_coded_concept_with_answers('Rotavirus vaccination given', 'Procedure', %w[Yes No])

    # Create IPV vaccination given concept (Coded, Procedure)
    puts "\n89. Creating IPV vaccination given concept..."
    create_coded_concept_with_answers('IPV vaccination given', 'Procedure', %w[Yes No])

    # Create Measles vaccination given concept (Coded, Procedure)
    puts "\n90. Creating Measles vaccination given concept..."
    create_coded_concept_with_answers('Measles vaccination given', 'Procedure', %w[Yes No])

    # Create Discharge Notes concept (Text, Misc)
    puts "\n91. Creating Discharge Notes concept..."
    create_text_concept('Discharge Notes', 'Misc')

    # Create Comments concept (Text, Misc)
    puts "\n92. Creating Comments concept..."
    create_text_concept('Comments', 'Misc')

    # Create Drug administration notes concept (Text, Misc)
    puts "\n93. Creating Drug administration notes concept..."
    create_text_concept('Drug administration notes', 'Misc')

    # Create Village concept (Text, Misc)
    puts "\n94. Creating Village concept..."
    create_text_concept('Village', 'Misc')

    # Create Sex concept (Coded, Misc)
    puts "\n95. Creating Sex concept..."
    create_coded_concept_with_answers('Sex', 'Misc', %w[Male Female])

    # Create Admission date concept (Date, Misc)
    puts "\n96. Creating Admission date concept..."
    create_date_concept('Admission date', 'Misc')

    # Create HIV status concept (Coded, Finding)
    puts "\n97. Creating HIV status concept..."
    create_coded_concept_with_answers('HIV status', 'Finding', %w[Positive Negative Unknown Exposed])

    # Create On ART concept (Coded, Finding)
    puts "\n98. Creating On ART concept..."
    create_coded_concept_with_answers('On ART', 'Finding', %w[Yes No])

    # Create Referral type concept (Coded, Misc)
    puts "\n99. Creating Referral type concept..."
    create_coded_concept_with_answers('Referral type', 'Misc', %w[Internal External])

    # Create Admission criteria concept (Coded, Misc)
    puts "\n100. Creating Admission criteria concept..."
    create_coded_concept_with_answers('Admission criteria', 'Misc',
                                      ['MUAC < 11.5cm', 'Bilateral pitting oedema', 'Medical complications'])

    # Create Severe unexplained wasting or malnutrition not responding... concept (Coded, Finding)
    puts "\n101. Creating Severe unexplained wasting or malnutrition not responding... concept..."
    create_coded_concept_with_answers('Severe unexplained wasting or malnutrition not responding...', 'Finding',
                                      %w[Yes No])

    # Create Type of feed concept (Coded, Finding)
    puts "\n102. Creating Type of feed concept..."
    create_coded_concept_with_answers('Type of feed', 'Finding', ['F-75', 'F-100', 'RUTF', 'Breast milk'])

    # Create Number of daily feeds concept (Numeric, Finding)
    puts "\n103. Creating Number of daily feeds concept..."
    create_numeric_concept('Number of daily feeds', 'Finding', nil, allow_decimal: false)

    # Create Amount per feed concept (Numeric, Finding)
    puts "\n104. Creating Amount per feed concept..."
    create_numeric_concept('Amount per feed', 'Finding', 'ml', allow_decimal: true)

    # Create Nasogastric (NG) tube in use concept (Coded, Finding)
    puts "\n105. Creating Nasogastric (NG) tube in use concept..."
    create_coded_concept_with_answers('Nasogastric (NG) tube in use', 'Finding', %w[Yes No])

    # Create Time concept (Text, Misc)
    puts "\n106. Creating Time concept..."
    create_text_concept('Time', 'Misc')

    # Create RUTF taken (fraction of sachet) concept (Numeric, Finding)
    puts "\n107. Creating RUTF taken (fraction of sachet) concept..."
    create_numeric_concept('RUTF taken (fraction of sachet)', 'Finding', nil, allow_decimal: true)

    # Create RUTF weekly sachet allocation concept (Numeric, Finding)
    puts "\n108. Creating RUTF weekly sachet allocation concept..."
    create_numeric_concept('RUTF weekly sachet allocation', 'Finding', 'sachets', allow_decimal: false)

    # Create Malaria Test Date concept (Date, Test)
    puts "\n109. Creating Malaria Test Date concept..."
    create_date_concept('Malaria Test Date', 'Test')

    # Create Discharging officer concept (Text, Misc)
    puts "\n110. Creating Discharging officer concept..."
    create_text_concept('Discharging officer', 'Misc')

    # Create Transfer site concept (Text, Misc)
    puts "\n111. Creating Transfer site concept..."
    create_text_concept('Transfer site', 'Misc')

    # Create Administering officer initials concept (Text, Misc)
    puts "\n112. Creating Administering officer initials concept..."
    create_text_concept('Administering officer initials', 'Misc')

    # Create Referred for HIV testing concept (Coded, Finding)
    puts "\n113. Creating Referred for HIV testing concept..."
    create_coded_concept_with_answers('Referred for HIV testing', 'Finding', %w[Yes No])

    # Create Current treatment phase concept (Coded, Finding)
    puts "\n114. Creating Current treatment phase concept..."
    create_coded_concept_with_answers('Current treatment phase', 'Finding',
                                      %w[Stabilization Transition Rehabilitation])

    puts "\n" + '=' * 80
    puts 'Successfully created nutrition concepts!'
    puts '=' * 80
  end
end

def create_program_states
  states = [
    {
      program_name: 'OTS/SFP PROGRAM',
      states: [
        { name: 'Admitted In OTS', initial: 1, terminal: 0 },
        { name: 'On SFP', initial: 1, terminal: 0 },
        { name: 'Cured In OTS', initial: 1, terminal: 0 },
        { name: 'Cured In SFP', initial: 0, terminal: 1 },
        { name: 'Defaulted In OTS', initial: 0, terminal: 1 },
        { name: 'Defaulted In SFP', initial: 0, terminal: 1 },
        { name: 'Died While In OTS', initial: 0, terminal: 1 },
        { name: 'Died While In SFP', initial: 0, terminal: 1 },
        { name: 'Not Responding To OTS Treatment', initial: 0, terminal: 1 },
        { name: 'Not Responding To SFP Treatment', initial: 0, terminal: 1 },
        { name: 'Referred To NRU', initial: 0, terminal: 1 },
        { name: 'Transferred Out', initial: 0, terminal: 1 },
        { name: 'Wrong Admission', initial: 0, terminal: 1 }
      ]
    },
    {
      program_name: 'NRU PROGRAM',
      states: [
        { name: 'Died', initial: 1, terminal: 0 },
        { name: 'Transferred Out', initial: 0, terminal: 1 },
        { name: 'Discharged To OTS/SFP', initial: 0, terminal: 1 },
        { name: 'Not Responding To Treatment', initial: 0, terminal: 1 }
      ]
    },
    {
      program_name: 'ICCM/CMAM PROGRAM',
      states: [
        { name: 'Cured', initial: 1, terminal: 0 },
        { name: 'Defaulted', initial: 0, terminal: 1 },
        { name: 'Died', initial: 0, terminal: 1 },
        { name: 'Not Responding To Treatment', initial: 0, terminal: 1 },
        { name: 'Referred To OTS/SFP', initial: 0, terminal: 1 },
        { name: 'Transferred Out', initial: 0, terminal: 1 }
      ]
    }
  ]
  create_impow_program_states(states)
end

# Example: Adding states for OTS/SFP Program
def create_impow_program_states(states)
  ActiveRecord::Base.transaction do
    states.each do |state|
      puts "\nCreating states for program: #{state[:program_name]}..."
      program = Program.find_by(name: state[:program_name])
      raise 'Program not found' unless program

      state[:states].each { |s| find_or_create_concept(s[:name]) }

      workflow = ProgramWorkflow.find_or_create_by!(
        program_id: program.program_id
      ) do |wf|
        wf.concept_id   = ConceptName.find_by!(name: 'Treatment status').concept_id
        wf.creator      = User.current.id
        wf.date_created = Time.current
        wf.date_changed = Time.current
        wf.changed_by   = User.current.id
        wf.uuid         = SecureRandom.uuid
      end

      state[:states].each do |s|
        concept = ConceptName.find_by!(name: s[:name]).concept

        find_or_create_workflow_state(
          workflow,
          concept,
          initial: s[:initial],
          terminal: s[:terminal]
        )
      end
    end
    puts "\n✓ All program states created successfully!"
  end
end

def find_or_create_concept(name)
  concept = ConceptName.find_by(name: name)&.concept
  if concept
    puts("⊙ Concept exists: #{name}")
    return concept
  end

  concept = Concept.create!(
    datatype_id: 4,
    class_id: 5,
    creator: User.current.id,
    date_created: Time.current,
    uuid: SecureRandom.uuid
  )

  ConceptName.create!(
    name: name,
    concept_id: concept.id,
    creator: User.current.id,
    locale: 'en',
    date_created: Time.current,
    uuid: SecureRandom.uuid
  )

  puts "✓ Created concept: #{name}"
  concept
end

def find_or_create_workflow_state(workflow, concept, initial:, terminal:)
  state = ProgramWorkflowState.find_by(
    program_workflow_id: workflow.id,
    concept_id: concept.id
  )

  puts("⊙ State exists: #{ConceptName.find_by(concept_id: concept.id).name}") if state
  return state if state

  state = ProgramWorkflowState.create!(
    concept_id: concept.id,
    program_workflow_id: workflow.id,
    initial: initial,
    terminal: terminal,
    creator: User.current.id,
    date_created: Time.current,
    uuid: SecureRandom.uuid
  )

  puts "✓ Created state: #{ConceptName.find_by(concept_id: concept.id).name}"
  state
end

def run_create_program
  User.current = User.find_by_username('admin') || User.first
  puts 'Creating OTS/SFP program and related concepts...'

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
      next unless ['ICCM/CMAM PROGRAM', 'OTS/SFP PROGRAM', 'NRU PROGRAM'].include?(program_name)

      program = Program.find_by(name: program_name)
      if program_name == 'OTS/SFP PROGRAM'
        program ||= Program.find_by(name: 'OTS Program')
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
  create_program_states
end

run_create_program
