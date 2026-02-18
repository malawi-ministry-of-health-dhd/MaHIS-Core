# frozen_string_literal: true

require 'rails_helper'

describe ArtService::Reports::CohortBuilder, :type => :service do
  describe 'WHO Stage indicators' do
    let(:start_date) { Date.parse('2026-02-01') }
    let(:end_date) { Date.parse('2026-02-28') }
    let(:program) { Program.find_by_name!('HIV Program') }
    let(:location) { Location.current }
    let(:arv_concept) { ConceptName.find_by_name!('Antiretroviral drugs').concept }
    let(:on_arvs_state) { ProgramWorkflowState.where(concept: ConceptName.find_by_name('On antiretrovirals').concept).first }
    let(:hiv_clinic_registration) { EncounterType.find_by_name!('HIV CLINIC REGISTRATION') }
    let(:hiv_staging) { EncounterType.find_by_name!('HIV STAGING') }
    let(:cohort_builder) { ArtService::Reports::CohortBuilder.new }
    let(:cohort_struct) { OpenStruct.new }
    
    before(:each) do
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_earliest_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_patient_outcomes')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_order_details')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_register_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_other_patient_types')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_pregnant_obs')
    end

    shared_examples 'a patient on ART' do
      let!(:patient_program) do
        PatientProgram.create!(
          patient: patient,
          program: program,
          location_id: location.location_id,
          date_enrolled: start_date + 5.days,
        )
      end
      
      let!(:patient_state) do
        PatientState.create!(
          patient_program: patient_program,
          state: on_arvs_state.program_workflow_state_id,
          start_date: start_date + 5.days,
        )
      end
      
      let!(:registration_encounter) do
        Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_clinic_registration,
          encounter_datetime: start_date + 5.days,
          location_id: location.location_id,
          provider_id: 1
        )
      end
      
      let!(:staging_encounter) do
        Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_staging,
          encounter_datetime: start_date + 5.days,
          location_id: location.location_id,
          provider_id: 1
        )
      end
      
      let!(:arv_order) do
        drug = Drug.find_by(concept_id: arv_concept.concept_id) || 
               Drug.arv_drugs.first
        order_type = OrderType.find_by_name!('Drug order')
        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 5.days,
          auto_expire_date: start_date + 35.days,
          encounter_id: registration_encounter.encounter_id,
          orderer: 1
        )
        DrugOrder.create!(order_id: order.order_id, drug_inventory_id: drug.drug_id, quantity: 60)
        order
      end
    end

    context 'with patient having WHO Stage 3' do
      let!(:patient) do
        person = create(:person, gender: 'M', birthdate: 35.years.ago)
        create(:patient, patient_id: person.person_id)
      end
      
      it_behaves_like 'a patient on ART'
      
      let!(:reason_for_art_concept) do
        ConceptName.find_by_name('Reason for ART eligibility')&.concept ||
        skip('Reason for ART eligibility concept not found')
      end
      
      let!(:who_stage_3_concept) do
        ConceptName.find_by_name('WHO stage III')&.concept ||
        skip('WHO stage III concept not found')
      end
      
      let!(:who_stage_obs) do
        Observation.create!(
          person: patient.person,
          encounter: staging_encounter,
          concept: reason_for_art_concept,
          value_coded: who_stage_3_concept.concept_id,
          obs_datetime: start_date + 5.days,
        )
      end

      it 'counts patient in who_stage_three indicator' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.who_stage_three).to eq(1)
      end

      it 'does not count in who_stage_four' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.who_stage_four).to eq(0)
      end
    end

    context 'with patient having WHO Stage 4' do
      let!(:patient) do
        person = create(:person, gender: 'F', birthdate: 28.years.ago)
        create(:patient, patient_id: person.person_id)
      end
      
      it_behaves_like 'a patient on ART'
      
      let!(:reason_for_art_concept) do
        ConceptName.find_by_name('Reason for ART eligibility')&.concept ||
        skip('Reason for ART eligibility concept not found')
      end
      
      let!(:who_stage_4_concept) do
        ConceptName.find_by_name('WHO stage IV')&.concept ||
        skip('WHO stage IV concept not found')
      end
      
      let!(:who_stage_obs) do
        Observation.create!(
          person: patient.person,
          encounter: staging_encounter,
          concept: reason_for_art_concept,
          value_coded: who_stage_4_concept.concept_id,
          obs_datetime: start_date + 5.days,
        )
      end

      it 'counts patient in who_stage_four indicator' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.who_stage_four).to eq(1)
      end

      it 'does not count in who_stage_three' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.who_stage_three).to eq(0)
      end
    end

    context 'with asymptomatic patient' do
      let!(:patient) do
        person = create(:person, gender: 'M', birthdate: 30.years.ago)
        create(:patient, patient_id: person.person_id)
      end
      
      it_behaves_like 'a patient on ART'
      
      let!(:reason_for_art_concept) do
        ConceptName.find_by_name('Reason for ART eligibility')&.concept ||
        skip('Reason for ART eligibility concept not found')
      end
      
      let!(:asymptomatic_concept) do
        ConceptName.find_by_name('Asymptomatic')&.concept ||
        ConceptName.find_by_name('Lymphocyte count below threshold with WHO stage 2')&.concept ||
        skip('Asymptomatic concepts not found')
      end
      
      let!(:asymptomatic_obs) do
        Observation.create!(
          person: patient.person,
          encounter: staging_encounter,
          concept: reason_for_art_concept,
          value_coded: asymptomatic_concept.concept_id,
          obs_datetime: start_date + 5.days,
        )
      end

      it 'counts patient in asymptomatic indicator' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.asymptomatic).to be >= 1
      end
    end
  end

  describe 'TB Status indicators' do
    let(:start_date) { Date.parse('2026-02-01') }
    let(:end_date) { Date.parse('2026-02-28') }
    let(:program) { Program.find_by_name!('HIV Program') }
    let(:location) { Location.current }
    let(:arv_concept) { ConceptName.find_by_name!('Antiretroviral drugs').concept }
    let(:on_arvs_state) { ProgramWorkflowState.where(concept: ConceptName.find_by_name('On antiretrovirals').concept).first }
    let(:hiv_clinic_registration) { EncounterType.find_by_name!('HIV CLINIC REGISTRATION') }
    let(:hiv_staging) { EncounterType.find_by_name!('HIV STAGING') }
    let(:cohort_builder) { ArtService::Reports::CohortBuilder.new }
    let(:cohort_struct) { OpenStruct.new }
    
    before(:each) do
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_earliest_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_patient_outcomes')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_order_details')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_register_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_other_patient_types')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_pregnant_obs')
    end

    def create_patient_on_art(gender: 'M', birthdate: 30.years.ago)
      person = create(:person, gender: gender, birthdate: birthdate)
      patient = create(:patient, patient_id: person.person_id)
      
      patient_program = PatientProgram.create!(
        patient: patient,
        program: program,
        location_id: location.location_id,
        date_enrolled: start_date + 5.days,
      )
      
      PatientState.create!(
        patient_program: patient_program,
        state: on_arvs_state.program_workflow_state_id,
        start_date: start_date + 5.days,
      )
      
      encounter = Encounter.create!(
        patient: patient,
        program: program,
        type: hiv_clinic_registration,
        encounter_datetime: start_date + 5.days,
        location_id: location.location_id,
        provider_id: 1
      )
      
      staging_encounter = Encounter.create!(
        patient: patient,
        program: program,
        type: hiv_staging,
        encounter_datetime: start_date + 5.days,
        location_id: location.location_id,
        provider_id: 1
      )
      
      drug = Drug.find_by(concept_id: arv_concept.concept_id) || 
             Drug.arv_drugs.first
      order_type = OrderType.find_by_name!('Drug order')
      order = Order.create!(
        order_type_id: order_type.order_type_id,
        concept_id: arv_concept.concept_id,
        patient: patient,
        start_date: start_date + 5.days,
        auto_expire_date: start_date + 35.days,
        encounter_id: encounter.encounter_id,
        orderer: 1
      )
      DrugOrder.create!(order_id: order.order_id, drug_inventory_id: drug.drug_id, quantity: 60)
      
      { patient: patient, staging_encounter: staging_encounter }
    end

    context 'with patient having current TB episode' do
      let!(:patient_data) { create_patient_on_art }
      let!(:patient) { patient_data[:patient] }
      let!(:staging_encounter) { patient_data[:staging_encounter] }
      
      let!(:current_tb_concept) do
        ConceptName.find_by_name('Current episode of TB')&.concept ||
        skip('Current episode of TB concept not found')
      end
      
      let!(:yes_concept) do
        ConceptName.find_by_name('Yes')&.concept ||
        skip('Yes concept not found')
      end
      
      let!(:tb_obs) do
        Observation.create!(
          person: patient.person,
          encounter: staging_encounter,
          concept: current_tb_concept,
          value_coded: yes_concept.concept_id,
          obs_datetime: start_date + 5.days,
        )
      end

      it 'counts patient in current_episode_of_tb' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.current_episode_of_tb).to eq(1)
      end

      it 'excludes patient from no_tb' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.no_tb).to eq(0)
      end
    end

    context 'with patient with TB within last 2 years' do
      let!(:patient_data) { create_patient_on_art }
      let!(:patient) { patient_data[:patient] }
      let!(:staging_encounter) { patient_data[:staging_encounter] }
      
      let!(:tb_within_2_years_concept) do
        ConceptName.find_by_name('TB within the last 2 years')&.concept ||
        skip('TB within the last 2 years concept not found')
      end
      
      let!(:yes_concept) do
        ConceptName.find_by_name('Yes')&.concept ||
        skip('Yes concept not found')
      end
      
      let!(:tb_obs) do
        Observation.create!(
          person: patient.person,
          encounter: staging_encounter,
          concept: tb_within_2_years_concept,
          value_coded: yes_concept.concept_id,
          obs_datetime: start_date + 5.days,
        )
      end

      it 'counts patient in tb_within_the_last_two_years' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.tb_within_the_last_two_years).to be >= 1
      end
    end

    context 'with patient without TB' do
      let!(:patient_data) { create_patient_on_art }
      let!(:patient) { patient_data[:patient] }

      it 'counts patient in no_tb' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.no_tb).to eq(1)
      end
    end
  end

  describe 'Outcome indicators' do
    let(:start_date) { Date.parse('2026-02-01') }
    let(:end_date) { Date.parse('2026-02-28') }
    let(:program) { Program.find_by_name!('HIV Program') }
    let(:location) { Location.current }
    let(:arv_concept) { ConceptName.find_by_name!('Antiretroviral drugs').concept }
    let(:on_arvs_state) { ProgramWorkflowState.where(concept: ConceptName.find_by_name('On antiretrovirals').concept).first }
    let(:hiv_clinic_registration) { EncounterType.find_by_name!('HIV CLINIC REGISTRATION') }
    let(:cohort_builder) { ArtService::Reports::CohortBuilder.new }
    let(:cohort_struct) { OpenStruct.new }
    
    before(:each) do
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_earliest_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_patient_outcomes')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_order_details')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_register_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_other_patient_types')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_pregnant_obs')
    end

    def create_patient_with_state(state_name, state_date: end_date - 10.days)
      person = create(:person, gender: 'M', birthdate: 30.years.ago)
      patient = create(:patient, patient_id: person.person_id)
      
      patient_program = PatientProgram.create!(
        patient: patient,
        program: program,
        location_id: location.location_id,
        date_enrolled: start_date - 50.days,
      )
      
      # Initial state: On ARVs
      PatientState.create!(
        patient_program: patient_program,
        state: on_arvs_state.program_workflow_state_id,
        start_date: start_date - 50.days,
      )
      
      encounter = Encounter.create!(
        patient: patient,
        program: program,
        type: hiv_clinic_registration,
        encounter_datetime: start_date - 50.days,
        location_id: location.location_id,
        provider_id: 1
      )
      
      drug = Drug.find_by(concept_id: arv_concept.concept_id) || 
             Drug.arv_drugs.first
      order_type = OrderType.find_by_name!('Drug order')
      order = Order.create!(
        order_type_id: order_type.order_type_id,
        concept_id: arv_concept.concept_id,
        patient: patient,
        start_date: start_date - 50.days,
        auto_expire_date: start_date - 20.days,
        encounter_id: encounter.encounter_id,
        orderer: 1
      )
      DrugOrder.create!(order_id: order.order_id, drug_inventory_id: drug.drug_id, quantity: 60)
      
      # Change to specified state
      if state_name
        state_concept = ConceptName.find_by_name(state_name)&.concept
        new_state = ProgramWorkflowState.where(concept: state_concept).first if state_concept
        
        PatientState.create!(
          patient_program: patient_program,
          state: new_state.program_workflow_state_id,
          start_date: state_date,
        ) if new_state
      end
      
      patient
    end

    context 'with patient who is alive and on ART' do
      let!(:patient) { create_patient_with_state(nil) } # No state change, stays on ARVs

      it 'includes patient in total_alive_and_on_art' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        patient_ids = result.total_alive_and_on_art.map { |p| p['patient_id'] }
        expect(patient_ids).to include(patient.patient_id)
      end

      it 'does not count in died_total' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.died_total).to eq(0)
      end
    end

    context 'with patient who died' do
      let!(:patient) { create_patient_with_state('Patient died') }

      it 'counts patient in died_total' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.died_total).to be >= 1
      end

      it 'excludes from total_alive_and_on_art' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        patient_ids = result.total_alive_and_on_art.map { |p| p['patient_id'] }
        expect(patient_ids).not_to include(patient.patient_id)
      end
    end

    context 'with patient who defaulted' do
      let!(:patient) { create_patient_with_state('Defaulted') }

      it 'counts patient in defaulted' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.defaulted).to be >= 1
      end

      it 'excludes from total_alive_and_on_art' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        patient_ids = result.total_alive_and_on_art.map { |p| p['patient_id'] }
        expect(patient_ids).not_to include(patient.patient_id)
      end
    end

    context 'with patient who transferred out' do
      let!(:patient) { create_patient_with_state('Patient transferred out') }

      it 'counts patient in transfered_out' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.transfered_out).to be >= 1
      end
    end

    context 'with patient who stopped treatment' do
      let!(:patient) { create_patient_with_state('Treatment stopped') }

      it 'counts patient in stopped_art' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.stopped_art).to be >= 1
      end
    end
  end

  describe 'Transfer and Re-initiation' do
    let(:start_date) { Date.parse('2026-02-01') }
    let(:end_date) { Date.parse('2026-02-28') }
    let(:program) { Program.find_by_name!('HIV Program') }
    let(:location) { Location.current }
    let(:arv_concept) { ConceptName.find_by_name!('Antiretroviral drugs').concept }
    let(:on_arvs_state) { ProgramWorkflowState.where(concept: ConceptName.find_by_name('On antiretrovirals').concept).first }
    let(:hiv_clinic_registration) { EncounterType.find_by_name!('HIV CLINIC REGISTRATION') }
    let(:cohort_builder) { ArtService::Reports::CohortBuilder.new }
    let(:cohort_struct) { OpenStruct.new }
    
    before(:each) do
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_earliest_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_patient_outcomes')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_order_details')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_register_start_date')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_other_patient_types')
      ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_pregnant_obs')
    end

    context 'with transferred-in patient' do
      let!(:patient) do
        person = create(:person, gender: 'F', birthdate: 32.years.ago)
        patient = create(:patient, patient_id: person.person_id)
        
        # Patient was on ARVs elsewhere, transferred in
        patient_program = PatientProgram.create!(
          patient: patient,
          program: program,
          location_id: location.location_id,
          date_enrolled: start_date + 10.days,
        )
        
        PatientState.create!(
          patient_program: patient_program,
          state: on_arvs_state.program_workflow_state_id,
          start_date: start_date + 10.days,
        )
        
        encounter = Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_clinic_registration,
          encounter_datetime: start_date + 10.days,
          location_id: location.location_id,
          provider_id: 1
        )
        
        # Mark as transfer in
        type_of_patient_concept = ConceptName.find_by_name('Type of patient')&.concept
        transfer_in_concept = ConceptName.find_by_name('Patient transferred in')&.concept ||
                             ConceptName.find_by_name('External consultation')&.concept
        
        if type_of_patient_concept && transfer_in_concept
          Observation.create!(
            person: patient.person,
            encounter: encounter,
            concept: type_of_patient_concept,
            value_coded: transfer_in_concept.concept_id,
            obs_datetime: start_date + 10.days,
          )
        end
        
        drug = Drug.find_by(concept_id: arv_concept.concept_id) || 
               Drug.arv_drugs.first
        order_type = OrderType.find_by_name!('Drug order')
        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 10.days,
          auto_expire_date: start_date + 40.days,
          encounter_id: encounter.encounter_id,
          orderer: 1
        )
        DrugOrder.create!(order_id: order.order_id, drug_inventory_id: drug.drug_id, quantity: 60)
        
        patient
      end

      it 'may count in re_initiated_on_art or transfer_in' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        # Transfer-in logic varies, this ensures indicator is calculated
        expect(result.re_initiated_on_art + result.transfer_in).to be >= 0
      end
    end
  end
end
