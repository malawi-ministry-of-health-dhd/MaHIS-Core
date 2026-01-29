# frozen_string_literal: true

namespace :concepts do
  desc 'Load Neonatal Triage concepts'
  task create_concepts: :environment do
    loader = CreateConcepts::ConceptLoader.new
    loader.load!
  end
end

module CreateConcepts
  class ConceptLoader
    CONCEPTS = CONCEPTS = [
      { name: 'Convulsing', datatype: 'Coded', class: 'Finding' },
      { name: 'Epigastric pains', datatype: 'Coded', class: 'Finding' },
      { name: 'Diminished fetal movements', datatype: 'Coded', class: 'Finding' },
      { name: 'Elective CS', datatype: 'Coded', class: 'Procedure' },
      { name: 'Pre-eclampsia/eclampsia', datatype: 'Coded', class: 'Diagnosis' },
      { name: 'PROM / PPROM', datatype: 'Coded', class: 'Diagnosis' },
      { name: 'Maternal infections', datatype: 'Coded', class: 'Diagnosis' },
      { name: 'Other medical/obstetric conditions (specify)', datatype: 'Text', class: 'Misc' },
      { name: 'Sick', datatype: 'Boolean', class: 'Finding' },
      { name: 'Intensive Care/Advanced Monitoring', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Need for Surgical Intervention', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Need for blood transfusion', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Specialist Consultation', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Lack of Neonatal Intensive Care Unit', datatype: 'Boolean', class: 'Finding' },
      { name: 'Need for Advanced Respiratory Life Support', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Need for Specialist Review', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Need for Exchange Transfusion', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Severe Complication Requiring Higher Level Care', datatype: 'Boolean', class: 'Diagnosis' },
      { name: 'Parent Request', datatype: 'Boolean', class: 'Misc' },
      { name: 'Time of delivery', datatype: 'Time', class: 'Question' },
      { name: 'Baby weight (grams)', datatype: 'Numeric', class: 'Finding' },
      { name: 'Baby height (cm)', datatype: 'Numeric', class: 'Finding' },
      { name: 'Specify Congenital Abnormalities', datatype: 'Text', class: 'Misc' },
      { name: 'Management given to newborn', datatype: 'Text', class: 'Procedure' },
      { name: 'Vitamin K given?', datatype: 'Coded', class: 'Question' },
      { name: 'Chlorhexidine 7.1% applied?', datatype: 'Coded', class: 'Question' },
      { name: 'IV Fluids', datatype: 'Coded', class: 'Drug' },
      { name: 'Date IV fluids were started', datatype: 'Date', class: 'Question' },
      { name: 'Time started', datatype: 'Time', class: 'Question' },
      { name: 'Time finished', datatype: 'Time', class: 'Question' },
      { name: 'Type of fluids', datatype: 'Coded', class: 'Drug' },
      { name: 'Specify other type of fluids', datatype: 'Text', class: 'Misc' },
      { name: 'Date of Transfusion', datatype: 'Date', class: 'Question' },
      { name: 'Time transfusion started', datatype: 'Time', class: 'Question' },
      { name: 'Time transfusion finished', datatype: 'Time', class: 'Question' },
      { name: 'Type of Blood', datatype: 'Coded', class: 'Misc' },
      { name: 'Other evacuations', datatype: 'Text', class: 'Procedure' },
      { name: 'Oxytocin 10 IU given', datatype: 'Coded', class: 'Drug' },
      { name: 'Misoprostol (400/600mcg orally) given?', datatype: 'Coded', class: 'Drug' },
      { name: 'Heat stable Cabitocin (100mcg IM/IV) given?', datatype: 'Coded', class: 'Drug' },
      { name: 'Ellavi drape used', datatype: 'Boolean', class: 'Misc' },
      { name: 'Cadre', datatype: 'Coded', class: 'Misc' },
      { name: 'Placenta length', datatype: 'Numeric', class: 'Finding' },
      { name: 'Specify other cord insertion', datatype: 'Text', class: 'Misc' },
      { name: 'Degree of tear', datatype: 'Coded', class: 'Finding' },
      { name: 'Causes', datatype: 'Text', class: 'Finding' },
      { name: 'Was E-MOTIVE bundle used', datatype: 'Boolean', class: 'Question' },
      { name: 'Early detection criteria', datatype: 'Coded', class: 'Finding' },
      { name: 'Uterine Massage', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Oxytocin 10IU in 500ml NS or RL over 10 mins given?', datatype: 'Boolean', class: 'Drug' },
      { name: 'Oxytocin 20IU in 1000ml NS or RL over 4 hrs given?', datatype: 'Boolean', class: 'Drug' },
      { name: 'Misoprostol 800mcg sublingual or rectal given?', datatype: 'Boolean', class: 'Drug' },
      { name: 'IV fluids given', datatype: 'Boolean', class: 'Drug' },
      { name: 'IV fluids volume (mls)', datatype: 'Numeric', class: 'Finding' },
      { name: 'Escalation done', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Escalation measures', datatype: 'Text', class: 'Procedure' },
      { name: 'Specify other escalation', datatype: 'Text', class: 'Misc' },
      { name: 'Maternal sepsis', datatype: 'Coded', class: 'Diagnosis' },
      { name: 'FAST M bundle given', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Anticonvulsant administered', datatype: 'Boolean', class: 'Drug' },
      { name: 'Antihypertensives administered', datatype: 'Boolean', class: 'Drug' },
      { name: 'Repair done', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Hysterectomy done', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Evacuation done', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Misoprostol administered', datatype: 'Boolean', class: 'Drug' },
      { name: 'Referral done', datatype: 'Boolean', class: 'Procedure' },
      { name: 'Pre-pregnant ART', datatype: 'Coded', class: 'Drug' },
      { name: 'During pregnant ART', datatype: 'Coded', class: 'Drug' },
      { name: 'Which regimen', datatype: 'Coded', class: 'Drug' },
      { name: 'Initial exam Heart rate', datatype: 'Numeric', class: 'Finding' },
      { name: 'Initial exam Temperature', datatype: 'Numeric', class: 'Finding' },
      { name: 'Last viral load test date', datatype: 'Date', class: 'Question' },
      { name: 'Viral load result copies', datatype: 'Numeric', class: 'Finding' },
      { name: 'Fontanelles', datatype: 'Coded', class: 'Finding' },
      { name: 'Molding', datatype: 'Coded', class: 'Finding' },
      { name: 'Lump', datatype: 'Coded', class: 'Finding' },
      { name: 'Eye Discharges', datatype: 'Coded', class: 'Finding' },
      { name: 'Ear Discharges', datatype: 'Coded', class: 'Finding' },
      { name: 'Presence of eye ball', datatype: 'Coded', class: 'Finding' },
      { name: 'Level of eyes to the ears', datatype: 'Coded', class: 'Finding' },
      { name: 'Symmetry', datatype: 'Coded', class: 'Finding' },
      { name: 'Shape', datatype: 'Coded', class: 'Finding' },
      { name: 'Nose Shape', datatype: 'Coded', class: 'Finding' },
      { name: 'Nose Discharges', datatype: 'Coded', class: 'Finding' },
      { name: 'Blockage', datatype: 'Coded', class: 'Finding' },
      { name: 'Deformities', datatype: 'Coded', class: 'Finding' },
      { name: 'Absence of the septum', datatype: 'Coded', class: 'Finding' },
      { name: 'sucking reflex', datatype: 'Coded', class: 'Finding' },
      { name: 'Tongue', datatype: 'Coded', class: 'Finding' },
      { name: 'False teeth', datatype: 'Coded', class: 'Finding' },
      { name: 'Webbing', datatype: 'Coded', class: 'Finding' },
      { name: 'Short neck', datatype: 'Coded', class: 'Finding' },
      { name: 'Murmurs', datatype: 'Coded', class: 'Finding' },
      { name: 'Chest assesment Respiratory rate', datatype: 'Numeric', class: 'Finding' },
      { name: 'Respiratory signs', datatype: 'Coded', class: 'Finding' },
      { name: 'Patent anus', datatype: 'Coded', class: 'Finding' },
      { name: 'Presence of all required orifices according to sex', datatype: 'Coded', class: 'Finding' },
      { name: 'Descended testicles', datatype: 'Coded', class: 'Finding' },
      { name: 'Capillary refill less than 3 seconds', datatype: 'Boolean', class: 'Finding' },
      { name: 'Extra assesment Pallor', datatype: 'Coded', class: 'Finding' },
      { name: 'Missing digits', datatype: 'Coded', class: 'Finding' },
      { name: 'Coldness', datatype: 'Coded', class: 'Finding' },
      { name: 'Erbs palsy', datatype: 'Coded', class: 'Finding' },
      { name: 'Fractures', datatype: 'Coded', class: 'Finding' },
      { name: 'Suckling', datatype: 'Coded', class: 'Finding' },
      { name: 'Rooting', datatype: 'Coded', class: 'Finding' },
      { name: 'Grasping', datatype: 'Coded', class: 'Finding' },
      { name: 'Stepping', datatype: 'Coded', class: 'Finding' },
      { name: 'State of membranes', datatype: 'Coded', class: 'Finding' },
      { name: 'Holder membranes', datatype: 'Coded', class: 'Finding' },
      { name: 'State of liquor', datatype: 'Coded', class: 'Finding' },
      { name: 'Corticosteroids doses (value_numeric)', datatype: 'Numeric', class: 'Drug' },
      { name: 'Contractions Remarks', datatype: 'Text', class: 'Misc' },
      { name: 'Fetal Station', datatype: 'Coded', class: 'Finding' },
      { name: 'Umbilical Cord', datatype: 'Coded', class: 'Finding' },
      { name: 'Pulsating', datatype: 'Boolean', class: 'Finding' },
      { name: 'Obstetric care provided', datatype: 'Coded', class: 'Procedure' },
      { name: 'Corticosteroids given', datatype: 'Boolean', class: 'Drug' },
      { name: 'FETAL ASSESSMENT', datatype: 'Text', class: 'Misc' },
      { name: 'Abdominal examination', datatype: 'Text', class: 'Finding' },
      { name: 'Is number of fetuses known?', datatype: 'Boolean', class: 'Question' }
    ].freeze

    def load!
      ActiveRecord::Base.transaction do
        CONCEPTS.each do |concept_data|
          find_or_create_concept!(concept_data)
        end
      end
      puts "Successfully loaded #{CONCEPTS.size} neonatal triage concepts"
    end

    private

    def find_or_create_concept!(concept_data)
      concept_name = concept_data[:name]

      existing_concept = Concept.joins(:concept_names)
                                .where(concept_name: { name: concept_name })
                                .first

      if existing_concept
        puts "Concept '#{concept_name}' already exists (concept_id: #{existing_concept.concept_id})"
        return existing_concept
      end

      datatype = ConceptDatatype.find_by(name: concept_data[:datatype])
      klass = ConceptClass.find_by(name: concept_data[:class])

      unless datatype && klass
        raise "Missing concept datatype (#{concept_data[:datatype]}) or concept class (#{concept_data[:class]})"
      end

      concept = Concept.create!(
        datatype_id: datatype.concept_datatype_id,
        class_id: klass.concept_class_id,
        creator: creator_id,
        date_created: Time.now,
        retired: 0,
        is_set: 0
      )

      ConceptName.create!(
        concept_id: concept.concept_id,
        name: concept_name,
        locale: 'en',
        concept_name_type: 'FULLY_SPECIFIED',
        creator: creator_id,
        date_created: Time.now
      )

      # Add numeric type metadata if applicable
      if concept_data[:datatype] == 'Numeric' && concept_data[:units]
        add_numeric_metadata(concept, concept_data[:units])
      end

      puts "Created concept '#{concept_name}' (concept_id: #{concept.concept_id})"
      concept
    end

    def add_numeric_metadata(concept, units)
      # Try to create concept numeric metadata
      begin
        ConceptNumeric.create!(
          concept_id: concept.concept_id,
          hi_absolute: nil,
          hi_critical: nil,
          hi_normal: nil,
          low_absolute: nil,
          low_critical: nil,
          low_normal: nil,
          units: units,
          precise: 1
        )
      rescue StandardError => e
        puts "  Warning: Could not create numeric metadata: #{e.message}"
      end
    end

    def creator_id
      @creator_id ||= User.unscoped.order(:user_id).pick(:user_id) || 1
    end
  end
end
