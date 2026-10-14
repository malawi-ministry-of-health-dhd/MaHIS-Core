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

  LEGACY_MEMBER_NAMES = {
    'At Risk of Hypoglycaemia' => ['At Risk Hypoglycaemia'],
    'Hypoglycaemia (NOT symptomatic)' => ['Hypoglycaemia Not Symptomatic'],
    'Hypoglycaemia (symptomatic)' => ['Hypoglycaemia Symptomatic'],
    'Risk factors for sepsis (Not symptomatic)' => ['Risk Factors Sepsis'],
    'Prematurity with Respiratory Distress' => ['Prematurity Respiratory Distress'],
    'Transient Tachypnoea of Newborn (TTN)' => ['TTN'],
    'Apnoea of prematurity' => ['Apnoea Prematurity'],
    'Low Birth Weight (1500-2499g)' => ['Low birth weight'],
    'Very Low Birth Weight (1000-1499g)' => ['Very Low Birth Weight'],
    'Extremely Low Birth Weight (<1000g)' => ['Extremely Low Birth Weight'],
    'Very Premature (28-31 weeks)' => ['Very Premature'],
    'Extremely Premature (<28 weeks)' => ['Extremely Premature'],
    'Term baby with Respiratory Distress' => ['Term Respiratory Distress'],
    'Hypoxic Ischaemic Encephalopathy/ Birth Asphyxia' => ['HIE Birth Asphyxia'],
    'Suspected Hypoxic Ischaemic Encephalopathy' => ['Suspected HIE'],
    'Cleft lip and/or palate' => ['Cleft Lip Palate'],
    'Congenital dislocation of the hip (CDH)' => ['CDH'],
    'Mild Talipes (club foot)' => ['Mild Talipes'],
    'Moderate Talipes (club foot)' => ['Moderate Talipes'],
    'Premature (32-36+6 weeks)' => ['Premature'],
    'High Birth Weight (>4000g at birth)' => ['High Birth Weight'],
    'Haemorrhagic disease of the newborn' => ['Haemorrhagic Disease']
  }.freeze

  SHARED_CONCEPT_NAMES = ['Low birth weight', 'TTN', 'HIV unknown'].freeze

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

  def english_names(concept_id)
    ConceptName.where(concept_id: concept_id, voided: 0, locale: 'en').order(:concept_name_id).to_a
  end

  def preferred_name(concept_id)
    names = english_names(concept_id)
    names.find { |n| n.concept_name_type == 'FULLY_SPECIFIED' && [true, 1, '1'].include?(n.locale_preferred) } ||
      names.find { |n| n.concept_name_type == 'FULLY_SPECIFIED' } ||
      names.first
  end

  def find_member_concept(set_concept_id, canonical_name)
    candidates = [canonical_name, *LEGACY_MEMBER_NAMES.fetch(canonical_name, [])].map(&:downcase)
    member_ids = ConceptSet.where(concept_set: set_concept_id).pluck(:concept_id)
    match = ConceptName.where(concept_id: member_ids, voided: 0)
                       .find { |n| candidates.include?(n.name.to_s.strip.downcase) }
    match && Concept.find(match.concept_id)
  end

  def shared_concept?(set_concept_id, concept_id)
    return true if ConceptSet.where(concept_id: concept_id).where.not(concept_set: set_concept_id).exists?

    english_names(concept_id).any? { |n| SHARED_CONCEPT_NAMES.any? { |shared| shared.casecmp?(n.name.to_s.strip) } }
  end

  def rename_in_place!(concept_id, canonical_name)
    names = english_names(concept_id)
    current = preferred_name(concept_id)
    exact = names.find { |n| n.name.to_s.strip.casecmp?(canonical_name) }

    if exact && exact.concept_name_id != current.concept_name_id
      exact.update_columns(name: canonical_name, concept_name_type: 'FULLY_SPECIFIED', locale_preferred: 1)
      keep = exact
    else
      old_name = current.name
      current.update_columns(name: canonical_name, concept_name_type: 'FULLY_SPECIFIED', locale_preferred: 1)
      keep = current
      unless old_name.to_s.strip.casecmp?(canonical_name) || names.any? { |n| n != current && n.name.to_s.strip.casecmp?(old_name.to_s.strip) }
        ConceptName.create!(
          concept_id: concept_id, name: old_name, locale: 'en', locale_preferred: 0, concept_name_type: nil,
          creator: creator_id, date_created: Time.zone.now, voided: 0, uuid: SecureRandom.uuid
        )
      end
    end

    ConceptName.where(concept_id: concept_id, voided: 0, locale: 'en')
               .where.not(concept_name_id: keep.concept_name_id)
               .update_all(locale_preferred: 0, concept_name_type: nil)
  end

  def replace_with_dedicated_concept!(set_concept_id, shared_concept_id, canonical_name)
    dedicated = find_or_create_member_concept!(canonical_name)
    ensure_membership!(set_concept_id, dedicated.concept_id)
    ConceptSet.where(concept_set: set_concept_id, concept_id: shared_concept_id).delete_all
    dedicated
  end

  def align_member!(set_concept_id, canonical_name, report)
    member = find_member_concept(set_concept_id, canonical_name)

    unless member
      created = find_or_create_member_concept!(canonical_name)
      ensure_membership!(set_concept_id, created.concept_id)
      member = created
    end

    current = preferred_name(member.concept_id)
    return if current&.name.to_s.strip == canonical_name

    if current&.name.to_s.strip.casecmp?(canonical_name)
      report[:recased] << "#{current.name} -> #{canonical_name} (concept #{member.concept_id})"
      current.update_columns(name: canonical_name)
      return
    end

    if !shared_concept?(set_concept_id, member.concept_id)
      rename_in_place!(member.concept_id, canonical_name)
      report[:renamed] << "#{current&.name} -> #{canonical_name} (concept #{member.concept_id})"
    elsif english_names(member.concept_id).any? { |n| n.name.to_s.strip.casecmp?(canonical_name) }
      report[:left_shared] << "#{canonical_name} (concept #{member.concept_id}, shown as '#{current&.name}')"
    else
      dedicated = replace_with_dedicated_concept!(set_concept_id, member.concept_id, canonical_name)
      report[:dedicated] << "#{canonical_name} (concept #{dedicated.concept_id}, replaces shared concept #{member.concept_id} '#{current&.name}')"
    end
  end

  desc 'Create/update Neonatal admission diagnoses concept set and members'
  task seed: :environment do
    report = Hash.new { |hash, key| hash[key] = [] }

    ActiveRecord::Base.transaction do
      set_concept = ensure_set_concept!

      MEMBER_CANONICAL_NAMES.each do |name|
        align_member!(set_concept.concept_id, name, report)
      end

      raise ActiveRecord::Rollback if ENV['DRY_RUN'] == 'true'
    end

    puts 'DRY RUN: no changes were saved' if ENV['DRY_RUN'] == 'true'

    {
      renamed: 'Renamed to CDS name',
      dedicated: 'New neonatal concept (shared concept kept unchanged)',
      recased: 'Capitalisation aligned to CDS name',
      left_shared: 'Shared concept already has the CDS name as a synonym (left unchanged)'
    }.each do |key, title|
      next if report[key].empty?

      puts "#{title}:"
      report[key].each { |line| puts "  - #{line}" }
    end

    set_id = ConceptName.find_by(name: SET_NAME, voided: 0)&.concept_id
    count = set_id ? ConceptSet.where(concept_set: set_id).distinct.count(:concept_id) : 0
    puts "Seeded '#{SET_NAME}' with #{count} members"
  end
end
