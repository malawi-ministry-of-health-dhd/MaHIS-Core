# frozen_string_literal: true

namespace :neonatal do
  desc 'Load neonatal drugs as concepts and create Neonate drugs concept set'
  task load_drugs: :environment do
    loader = NeonatalDrugs::DrugLoader.new
    loader.load!
  end

  desc 'Verify if neonatal drugs with Neonate drugs concept set exist in CouchDB'
  task verify_drugs_in_couchdb: :environment do
    verifier = NeonatalDrugs::CouchDBVerifier.new
    verifier.verify!
  end
end

module NeonatalDrugs
  class DrugLoader
    # Neonatal drugs list
    NEONATAL_DRUGS = [
      # Medications
      'Surfactant',
      'Caffein',
      'Aminophylline',
      'Ferrous supplement syrup - Not quantified',
      'Folic acid Syrup - Not quantified',
      'Multivitamin  special for newborns',
      'Vitamin D syrup',
      'Benzyl penicillline',
      'Gentamycin',
      'Ceftriaxone',
      'Meropenem',
      'Vancomicin',
      'Piperacillin-Tazobactam',
      'Amikacin',
      'Phenobarbitone',
      'Diazepam',
      'Phenytoin',
      'Livieracetam (Keppra)',
      'Flucloxacillin IV',
      'Amphotericin B',
      'Aciclovir IV',
      'Adrenaline',
      'Dobutamine',
      'Dopamine',
      'Morphine IV',
      'Potassium Chloride',
      'Sodium Bicarbonate',
      'Calcium Gluconate',
      'Insulin - Short acting',
      'Ciprofloxacillin IV',
      'TPN',
      'Mid-Chain Triglyceride (MCT) Oil',
      # Fluids and Blood products
      'Ringers lactate',
      'Normal saline',
      '5% dextrose',
      '50% dextrose',
      'Neonatalite',
      'Water for injection',
      'Blood',
      'Platelets',
      'Fresh frozen plasma',
    ].freeze

    CONCEPT_SET_NAME = 'Neonate drugs'

    def load!
      ActiveRecord::Base.transaction do
        puts "\n===== Loading Neonatal Drugs ====="

        # Step 1: Create or find the concept set
        concept_set_concept = find_or_create_concept_set!

        # Step 2: Create drug concepts and add to concept set
        drug_concepts = []
        NEONATAL_DRUGS.each do |drug_name|
          drug_concept = find_or_create_drug_concept!(drug_name)
          drug_concepts << drug_concept
          add_to_concept_set!(concept_set_concept, drug_concept)
        end

        # Step 3: Create Drug records for each concept
        drug_concepts.each do |concept|
          find_or_create_drug_record!(concept)
        end

        puts "\n===== Summary ====="
        puts "Successfully loaded #{NEONATAL_DRUGS.size} neonatal drugs"
        puts "Concept set: #{CONCEPT_SET_NAME} (concept_id: #{concept_set_concept.concept_id})"
        puts "All drugs added to concept set and drug inventory"
      end
    end

    private

    def find_or_create_concept_set!
      puts "\n--- Creating Concept Set ---"

      existing_concept = Concept.joins(:concept_names)
                                .where(concept_name: { name: CONCEPT_SET_NAME })
                                .first

      if existing_concept
        puts "Concept set '#{CONCEPT_SET_NAME}' already exists (concept_id: #{existing_concept.concept_id})"
        return existing_concept
      end

      datatype = ConceptDatatype.find_by(name: 'N/A')
      klass = ConceptClass.find_by(name: 'ConvSet')

      unless datatype && klass
        raise "Missing required concept datatype 'N/A' or concept class 'ConvSet'"
      end

      concept = Concept.create!(
        datatype_id: datatype.concept_datatype_id,
        class_id: klass.concept_class_id,
        creator: creator_id,
        date_created: Time.now,
        retired: 0,
        is_set: 1
      )

      ConceptName.create!(
        concept_id: concept.concept_id,
        name: CONCEPT_SET_NAME,
        locale: 'en',
        concept_name_type: 'FULLY_SPECIFIED',
        creator: creator_id,
        date_created: Time.now
      )

      puts "Created concept set '#{CONCEPT_SET_NAME}' (concept_id: #{concept.concept_id})"
      concept
    end

    def find_or_create_drug_concept!(drug_name)
      existing_concept = Concept.joins(:concept_names)
                                .where(concept_name: { name: drug_name })
                                .first

      if existing_concept
        puts "Drug concept '#{drug_name}' already exists (concept_id: #{existing_concept.concept_id})"
        return existing_concept
      end

      datatype = ConceptDatatype.find_by(name: 'N/A')
      klass = ConceptClass.find_by(name: 'Drug')

      unless datatype && klass
        raise "Missing required concept datatype 'N/A' or concept class 'Drug'"
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
        name: drug_name,
        locale: 'en',
        concept_name_type: 'FULLY_SPECIFIED',
        creator: creator_id,
        date_created: Time.now
      )

      puts "Created drug concept '#{drug_name}' (concept_id: #{concept.concept_id})"
      concept
    end

    def add_to_concept_set!(set_concept, member_concept)
      existing_member = ConceptSet.find_by(
        concept_set: set_concept.concept_id,
        concept_id: member_concept.concept_id
      )

      if existing_member
        puts "  '#{member_concept.concept_names.first.name}' already in concept set"
        return existing_member
      end

      concept_set = ConceptSet.create!(
        concept_set: set_concept.concept_id,
        concept_id: member_concept.concept_id,
        sort_weight: 1.0,
        creator: creator_id,
        date_created: Time.now
      )

      puts "  Added '#{member_concept.concept_names.first.name}' to concept set"
      concept_set
    end

    def find_or_create_drug_record!(concept)
      drug_name = concept.concept_names.first.name

      existing_drug = Drug.unscoped.find_by(concept_id: concept.concept_id)

      if existing_drug
        puts "  Drug record for '#{drug_name}' already exists (drug_id: #{existing_drug.drug_id})"
        return existing_drug
      end

      # Get a default dosage form (e.g., "Tablet" or "Unknown")
      dosage_form = get_default_dosage_form

      drug = Drug.create!(
        concept_id: concept.concept_id,
        name: drug_name,
        dosage_form: dosage_form&.concept_id,
        combination: 0,
        retired: 0,
        creator: creator_id,
        date_created: Time.now,
        uuid: SecureRandom.uuid
      )

      puts "  Created drug record for '#{drug_name}' (drug_id: #{drug.drug_id})"
      drug
    end

    def get_default_dosage_form
      @default_form ||= begin
        form_name = ConceptName.where(name: ['Unknown', 'Tablet', 'Solution']).first
        form_name&.concept
      end
    end

    def creator_id
      @creator_id ||= User.unscoped.order(:user_id).pick(:user_id) || 1
    end
  end
end
