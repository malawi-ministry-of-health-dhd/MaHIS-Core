# frozen_string_literal: true

class AddMissingCxcaConcepts < ActiveRecord::Migration[7.0]
  def up
    # Add concepts needed for CxCa workflow
    add_cxca_concepts
  end

  def down
    # Remove the dummy concepts when rolling back
    remove_cxca_concepts
  end

  private

  def add_cxca_concepts
    # Concept datatypes and classes (assuming these exist from skeleton data)
    test_class_id = ConceptClass.find_by(name: 'Test')&.concept_class_id || 1
    finding_class_id = ConceptClass.find_by(name: 'Finding')&.concept_class_id || 5
    na_datatype_id = ConceptDatatype.find_by(name: 'N/A')&.concept_datatype_id || 4

    current_user_id = 1 # System user ID

    # Create CxCa test concept
    unless ConceptName.find_by(name: 'CxCa test')
      cxca_test_concept = Concept.create!(
        class_id: test_class_id,
        datatype_id: na_datatype_id,
        creator: current_user_id,
        date_created: Time.current,
        uuid: SecureRandom.uuid
      )

      ConceptName.create!(
        concept: cxca_test_concept,
        name: 'CxCa test',
        concept_name_type: 'FULLY_SPECIFIED',
        creator: current_user_id,
        date_created: Time.current,
        uuid: SecureRandom.uuid
      )

      puts "Created concept: CxCa test (ID: #{cxca_test_concept.concept_id})"
    else
      puts "Concept 'CxCa test' already exists"
    end

    # Create Cancer Suspect concept (using "Suspect cancer" as it's more common in the codebase)
    unless ConceptName.find_by(name: 'Suspect cancer')
      cancer_suspect_concept = Concept.create!(
        class_id: finding_class_id,
        datatype_id: na_datatype_id,
        creator: current_user_id,
        date_created: Time.current,
        uuid: SecureRandom.uuid
      )

      ConceptName.create!(
        concept: cancer_suspect_concept,
        name: 'Suspect cancer',
        concept_name_type: 'FULLY_SPECIFIED',
        creator: current_user_id,
        date_created: Time.current,
        uuid: SecureRandom.uuid
      )

      puts "Created concept: Suspect cancer (ID: #{cancer_suspect_concept.concept_id})"
    else
      puts "Concept 'Suspect cancer' already exists"
    end

    # Create alternative name "Cancer Suspect" for the same concept (if needed)
    suspect_cancer_concept = ConceptName.find_by(name: 'Suspect cancer')&.concept
    if suspect_cancer_concept && !ConceptName.find_by(name: 'Cancer Suspect')
      ConceptName.create!(
        concept: suspect_cancer_concept,
        name: 'Cancer Suspect',
        concept_name_type: 'SHORT',
        creator: current_user_id,
        date_created: Time.current,
        uuid: SecureRandom.uuid
      )
      puts "Created alternative name: Cancer Suspect"
    end
  end

  def remove_cxca_concepts
    # Find and remove CxCa test concept
    cxca_test_concept_name = ConceptName.find_by(name: 'CxCa test')
    if cxca_test_concept_name
      concept = cxca_test_concept_name.concept
      concept.concept_names.destroy_all
      concept.destroy
      puts "Removed concept: CxCa test"
    end

    # Find and remove Suspect cancer concept
    suspect_cancer_concept_name = ConceptName.find_by(name: 'Suspect cancer')
    if suspect_cancer_concept_name
      concept = suspect_cancer_concept_name.concept
      concept.concept_names.destroy_all
      concept.destroy
      puts "Removed concept: Suspect cancer"
    end
  end
end