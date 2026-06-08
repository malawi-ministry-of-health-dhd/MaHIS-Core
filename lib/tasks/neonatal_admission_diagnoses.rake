# frozen_string_literal: true

require 'securerandom'

namespace :neonatal_admission_diagnoses do
  SET_NAME = 'Neonatal admission diagnoses'

  MEMBER_CANONICAL_NAMES = [
    'Abscess',
    'Anaemia',
    'At Risk of Hypoglycaemia',
    'Birth Injury/Trauma',
    'Bowel Obstruction',
    'Congenital Abnormality',
    'Congenital Heart Disease',
    'Dehydration',
    'Difficulty Feeding',
    'Abandoned Baby',
    'HIV Low Risk',
    'HIV High Risk',
    'HIV Unknown',
    'Hypoglycaemia (NOT symptomatic)',
    'Hypoglycaemia (symptomatic)',
    'Gastroschisis',
    'Possible Meconium Aspiration',
    'Suspected Neonatal Sepsis',
    'Risk factors for sepsis (Not symptomatic)',
    'Prematurity with Respiratory Distress',
    'Physiological Jaundice',
    'Transient Tachypnoea of Newborn (TTN)',
    'Umbilical Hernia',
    'Meningitis',
    'Ambiguous Genitalia',
    'Apnoea of prematurity',
    'Low Birth Weight (1500-2499g)',
    'Very Low Birth Weight (1000-1499g)',
    'Extremely Low Birth Weight (<1000g)',
    'Very Premature (28-31 weeks)',
    'Extremely Premature (<28 weeks)',
    'Convulsions',
    'Mild Hypothermia',
    'Moderate Hypothermia',
    'Severe Hypothermia',
    'Hyperthermia',
    'Term baby with Respiratory Distress',
    'Pathological Jaundice',
    'Hypoxic Ischaemic Encephalopathy/ Birth Asphyxia',
    'Suspected Hypoxic Ischaemic Encephalopathy',
    'Prolonged Jaundice',
    'Cleft lip and/or palate',
    'Cleft lip and/or palate with RD',
    'Cleft lip',
    'Myelomeningocele',
    'Omphalocele',
    'Congenital dislocation of the hip (CDH)',
    'Mild Talipes (club foot)',
    'Moderate Talipes (club foot)',
    'Pneumonia',
    'Bronchiolitis',
    'Syphilis Exposed',
    'Suspected congenital syphilis',
    'Hydrocephalus',
    'Microcephaly',
    'Fracture',
    'Tracheoesphageal fistula',
    'Born before arrival',
    'Normal Baby',
    'Necrotising enterocolitis',
    'Meconium Exposure',
    'Premature (32-36+6 weeks)',
    'High Birth Weight (>4000g at birth)',
    'Haemorrhagic disease of the newborn',
    'Malaria',
    'Safekeeping',
    'Trisomy 13',
    'Retinopathy of prematurity',
    'Other'
  ].freeze

  def creator_id
    @creator_id ||= User.unscoped.order(:user_id).pick(:user_id) || 1
  end

  def create_concept_name!(concept_id, name)
    ConceptName.create!(
      concept_id: concept_id,
      name: name,
      locale: 'en',
      locale_preferred: 1,
      concept_name_type: 'FULLY_SPECIFIED',
      creator: creator_id,
      date_created: Time.zone.now,
      voided: 0,
      uuid: SecureRandom.uuid
    )
  end

  def ensure_set_concept!
    existing = Concept.find_by_name(SET_NAME)
    return existing if existing

    datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.find_by(name: 'Coded')
    klass = ConceptClass.find_by(name: 'ConvSet') || ConceptClass.find_by(name: 'Conv') || ConceptClass.find_by(name: 'Question')
    raise 'Missing concept datatype/class for neonatal diagnosis concept set' unless datatype && klass

    concept = Concept.create!(
      datatype_id: datatype.concept_datatype_id,
      class_id: klass.concept_class_id,
      creator: creator_id,
      date_created: Time.zone.now,
      retired: 0,
      is_set: 1,
      uuid: SecureRandom.uuid
    )

    create_concept_name!(concept.concept_id, SET_NAME)
    concept
  end

  def find_or_create_member_concept!(name)
    existing = Concept.find_by_name(name)
    return existing if existing

    datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.find_by(name: 'Coded')
    klass = ConceptClass.find_by(name: 'Diagnosis') || ConceptClass.find_by(name: 'Misc')
    raise "Missing concept datatype/class for neonatal diagnosis '#{name}'" unless datatype && klass

    concept = Concept.create!(
      datatype_id: datatype.concept_datatype_id,
      class_id: klass.concept_class_id,
      creator: creator_id,
      date_created: Time.zone.now,
      retired: 0,
      is_set: 0,
      uuid: SecureRandom.uuid
    )

    create_concept_name!(concept.concept_id, name)
    concept
  end

  def ensure_membership!(set_concept_id, member_concept_id)
    return if ConceptSet.exists?(concept_set: set_concept_id, concept_id: member_concept_id)

    ConceptSet.create!(
      concept_set: set_concept_id,
      concept_id: member_concept_id,
      creator: creator_id,
      date_created: Time.zone.now,
      uuid: SecureRandom.uuid
    )
  end

  desc 'Create/update Neonatal admission diagnoses concept set and members'
  task seed: :environment do
    ActiveRecord::Base.transaction do
      set_concept = ensure_set_concept!

      MEMBER_CANONICAL_NAMES.each do |name|
        member_concept = find_or_create_member_concept!(name)
        ensure_membership!(set_concept.concept_id, member_concept.concept_id)
      end
    end

    set_id = ConceptName.find_by(name: SET_NAME, voided: 0)&.concept_id
    count = set_id ? ConceptSet.where(concept_set: set_id).distinct.count(:concept_id) : 0
    puts "Seeded '#{SET_NAME}' with #{count} members"
  end
end
