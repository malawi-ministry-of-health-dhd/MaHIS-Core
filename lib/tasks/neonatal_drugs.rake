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

  desc 'Dump all neonatal drugs from the database'
  task dump_drugs: :environment do
    loader = NeonatalDrugs::DrugDumper.new
    loader.dump!
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

  class DrugDumper
    CONCEPT_SET_NAME = 'Neonate drugs'

    def dump!
      puts "\n===== Dumping Neonatal Drugs ====="

      # Get the concept set
      concept_set_concept = Concept.joins(:concept_names)
                                   .where(concept_name: { name: CONCEPT_SET_NAME })
                                   .first

      unless concept_set_concept
        puts "ERROR: Concept set '#{CONCEPT_SET_NAME}' not found!"
        return
      end

      puts "\n--- Concept Set Info ---"
      puts "Concept ID: #{concept_set_concept.concept_id}"
      puts "Name: #{CONCEPT_SET_NAME}"

      # Get all drugs in this concept set
      drug_concepts = ConceptSet.where(concept_set: concept_set_concept.concept_id)
                                .includes(concept: :concept_names)

      puts "\n--- Drugs in Concept Set (#{drug_concepts.count} total) ---"

      drug_concepts.each_with_index do |concept_set_entry, index|
        concept = concept_set_entry.concept
        concept_name = concept.concept_names.first&.name || "Unknown"

        # Find the actual Drug record
        drug = Drug.unscoped.find_by(concept_id: concept.concept_id)

        puts "\n#{index + 1}. #{concept_name}"
        puts "   Concept ID: #{concept.concept_id}"

        if drug
          puts "   Drug ID: #{drug.drug_id}"
          puts "   Drug Name: #{drug.name}"
          puts "   Retired: #{drug.retired}"

          # Check all concept sets this drug belongs to
          all_sets = ConceptSet.where(concept_id: concept.concept_id)
                              .includes(set: :concept_names)

          if all_sets.count > 1
            puts "   Also in concept sets:"
            all_sets.each do |cs|
              next if cs.concept_set == concept_set_concept.concept_id
              set_name = cs.set.concept_names.first&.name || "Unknown"
              puts "     - #{set_name} (ID: #{cs.concept_set})"
            end
          end
        else
          puts "   WARNING: No Drug record found!"
        end
      end

      puts "\n===== Summary ====="
      puts "Total drugs in '#{CONCEPT_SET_NAME}' concept set: #{drug_concepts.count}"
    end
  end

  class CouchDBVerifier
    CONCEPT_SET_NAME = 'Neonate drugs'

    def verify!
      puts "\n===== Verifying Neonatal Drugs in CouchDB ====="

      # Check if CouchDB is configured
      unless ENV['COUCHDB_HOST']
        puts "ERROR: CouchDB not configured (COUCHDB_HOST not set)"
        return
      end

      # Get the concept set
      concept_set_concept = Concept.joins(:concept_names)
                                   .where(concept_name: { name: CONCEPT_SET_NAME })
                                   .first

      unless concept_set_concept
        puts "ERROR: Concept set '#{CONCEPT_SET_NAME}' not found in database!"
        return
      end

      concept_set_id = concept_set_concept.concept_id
      puts "Concept set ID: #{concept_set_id}"

      # Get all drugs in this concept set from MySQL
      drug_concepts = ConceptSet.where(concept_set: concept_set_id)
                                .includes(concept: :concept_names)

      expected_drug_count = drug_concepts.count
      puts "Expected drugs in concept set: #{expected_drug_count}"

      # Try to connect to CouchDB
      begin
        require 'couchrest'

        protocol = ENV['COUCHDB_PROTOCOL'] || 'http'
        host = ENV['COUCHDB_HOST']
        port = ENV['COUCHDB_PORT'] || '5984'
        username = ENV['COUCHDB_USERNAME']
        password = ENV['COUCHDB_PASSWORD']

        url = if username && password
                "#{protocol}://#{username}:#{password}@#{host}:#{port}"
              else
                "#{protocol}://#{host}:#{port}"
              end

        couch = CouchRest.new(url)
        db = couch.database!('drugs')

        puts "\n--- Checking CouchDB ---"

        # Get all docs from CouchDB
        all_docs = db.all_docs(include_docs: true)
        total_docs = all_docs['rows'].length
        puts "Total documents in CouchDB: #{total_docs}"

        # Check which drugs have the concept_set_id
        drugs_with_old_format = 0
        drugs_with_new_format = 0
        drugs_in_neonate_set = []

        all_docs['rows'].each do |row|
          doc = row['doc']
          next unless doc

          # Check old format (single concept_set_id)
          if doc['concept_set_id'] == concept_set_id
            drugs_with_old_format += 1
            drugs_in_neonate_set << doc['name']
          end

          # Check new format (concept_set_ids array)
          if doc['concept_set_ids']&.include?(concept_set_id)
            drugs_with_new_format += 1
            drugs_in_neonate_set << doc['name'] unless drugs_in_neonate_set.include?(doc['name'])
          end
        end

        puts "\n--- Results ---"
        puts "Drugs with old format (single concept_set_id): #{drugs_with_old_format}"
        puts "Drugs with new format (concept_set_ids array): #{drugs_with_new_format}"
        puts "Total unique drugs found: #{drugs_in_neonate_set.uniq.count}"

        if drugs_in_neonate_set.uniq.count == expected_drug_count
          puts "SUCCESS: All #{expected_drug_count} neonatal drugs found in CouchDB!"
        else
          puts "ERROR: Missing drugs! Expected #{expected_drug_count}, found #{drugs_in_neonate_set.uniq.count}"
          puts "\nDrugs found in CouchDB:"
          drugs_in_neonate_set.uniq.sort.each { |name| puts "  - #{name}" }
        end

      rescue LoadError
        puts "ERROR: CouchRest gem not available. Install with: gem install couchrest"
      rescue StandardError => e
        puts "ERROR: Error connecting to CouchDB: #{e.message}"
        puts e.backtrace.first(5).join("\n")
      end
    end
  end
end
