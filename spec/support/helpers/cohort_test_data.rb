# frozen_string_literal: true

module Helpers
  module CohortTestData
    def setup_cohort_test_data
      setup_programs
      setup_concepts
      setup_encounter_types
      setup_program_workflows
      setup_arv_drug_view
    end

    private

    def setup_programs
      # Create HIV Program if it doesn't exist
      return if Program.find_by(name: 'HIV PROGRAM')

      hiv_concept = Concept.create!(
        datatype_id: 4, # N/A
        class_id: 10,   # Misc
        is_set: 0,
        creator: 1,
        date_created: Time.now,
        retired: 0,
        uuid: SecureRandom.uuid
      )

      ConceptName.create!(
        concept: hiv_concept,
        name: 'HIV PROGRAM',
        locale: 'en',
        creator: 1,
        date_created: Time.now,
        voided: 0,
        uuid: SecureRandom.uuid
      )

      Program.create!(
        program_id: 1,
        concept_id: hiv_concept.concept_id,
        name: 'HIV PROGRAM',
        description: 'HIV/AIDS Treatment Program',
        creator: 1,
        date_created: Time.now,
        retired: 0,
        uuid: SecureRandom.uuid
      )
    end

    def setup_concepts
      concepts_to_create = {
        'Antiretroviral drugs' => { datatype: 4, class: 10 },
        'Is patient pregnant?' => { datatype: 2, class: 7 },
        'Reason for ART eligibility' => { datatype: 2, class: 7 },
        'On antiretrovirals' => { datatype: 2, class: 11 },
        'Type of patient' => { datatype: 2, class: 7 },
        'Drug refill' => { datatype: 2, class: 11 },
        'New patient' => { datatype: 2, class: 11 },
        'External Consultation' => { datatype: 2, class: 11 },
        'Amount dispensed' => { datatype: 1, class: 11 }, # Numeric
        'Method of family planning' => { datatype: 2, class: 7 },
        'Family planning, action to take' => { datatype: 2, class: 7 },
        'None' => { datatype: 2, class: 11 },
        'No' => { datatype: 2, class: 11 },
        'Yes' => { datatype: 2, class: 11 },
        'Isoniazid' => { datatype: 2, class: 7 },
        'Pyridoxine' => { datatype: 2, class: 7 },
        'Cotrimoxazole' => { datatype: 2, class: 7 },
        'Drug order adherence' => { datatype: 2, class: 7 },
        'TB Suspected' => { datatype: 2, class: 11 },
        'TB Not Suspected' => { datatype: 2, class: 11 },
        'Confirmed TB NOT on Treatment' => { datatype: 2, class: 11 },
        'Confirmed TB on Treatment' => { datatype: 2, class: 11 },
        'KAPOSIS SARCOMA' => { datatype: 2, class: 7 },
        'Who stages criteria present' => { datatype: 2, class: 7 },
        'EXTRAPULMONARY TUBERCULOSIS (EPTB)' => { datatype: 2, class: 7 },
        'PULMONARY TUBERCULOSIS' => { datatype: 2, class: 7 },
        'PULMONARY TUBERCULOSIS (CURRENT)' => { datatype: 2, class: 7 },
        'Pulmonary tuberculosis within the last 2 years' => { datatype: 2, class: 7 },
        'Ptb within the past two years' => { datatype: 2, class: 7 },
        'WHO STAGES CRITERIA PRESENT' => { datatype: 2, class: 7 }
      }

      concepts_to_create.each do |name, attrs|
        next if ConceptName.find_by(name: name)

        concept = Concept.create!(
          datatype_id: attrs[:datatype],
          class_id: attrs[:class],
          is_set: 0,
          creator: 1,
          date_created: Time.now,
          retired: 0,
          uuid: SecureRandom.uuid
        )

        ConceptName.create!(
          concept: concept,
          name: name,
          locale: 'en',
          creator: 1,
          date_created: Time.now,
          voided: 0,
          uuid: SecureRandom.uuid
        )
      end
    end

    def setup_encounter_types
      encounter_types = [
        'HIV CLINIC REGISTRATION',
        'HIV STAGING',
        'DISPENSING',
        'HIV CLINIC CONSULTATION'
      ]

      encounter_types.each do |name|
        next if EncounterType.find_by(name: name)

        EncounterType.create!(
          name: name,
          description: name,
          creator: 1,
          date_created: Time.now,
          retired: 0,
          uuid: SecureRandom.uuid
        )
      end
    end

    def setup_program_workflows
      program = Program.find_by(name: 'HIV PROGRAM')
      return unless program

      # Check if workflow already exists
      existing_workflow = ProgramWorkflow.find_by(program: program)
      return if existing_workflow

      # Create a workflow concept
      workflow_concept = Concept.create!(
        datatype_id: 4, # N/A
        class_id: 10,   # Misc
        is_set: 0,
        creator: 1,
        date_created: Time.now,
        retired: 0,
        uuid: SecureRandom.uuid
      )

      ConceptName.create!(
        concept: workflow_concept,
        name: 'Treatment Status',
        locale: 'en',
        creator: 1,
        date_created: Time.now,
        voided: 0,
        uuid: SecureRandom.uuid
      )

      # Create Treatment Status workflow
      workflow = ProgramWorkflow.create!(
        program: program,
        concept_id: workflow_concept.concept_id,
        creator: 1,
        date_created: Time.now,
        retired: 0,
        uuid: SecureRandom.uuid
      )

      # Create "On antiretrovirals" state
      on_arvs_concept = ConceptName.find_by(name: 'On antiretrovirals')&.concept
      return unless on_arvs_concept && !ProgramWorkflowState.find_by(concept_id: on_arvs_concept.concept_id)

      ProgramWorkflowState.create!(
        program_workflow: workflow,
        concept_id: on_arvs_concept.concept_id,
        initial: 0,
        terminal: 0,
        creator: 1,
        date_created: Time.now,
        retired: 0,
        uuid: SecureRandom.uuid
      )
    end

    def setup_arv_drug_view
      # Create the arv_drug view if it doesn't exist
      arv_concept = ConceptName.find_by(name: 'Antiretroviral drugs')&.concept
      return unless arv_concept

      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE OR REPLACE VIEW arv_drug AS#{' '}
        SELECT drug.drug_id AS drug_id#{' '}
        FROM drug#{' '}
        WHERE drug.concept_id IN (
          SELECT concept_set.concept_id#{' '}
          FROM concept_set#{' '}
          WHERE concept_set.concept_set = #{arv_concept.concept_id}
        )
      SQL
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("Failed to create arv_drug view: #{e.message}")
    end
  end
end
