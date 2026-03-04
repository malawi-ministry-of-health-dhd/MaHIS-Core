# frozen_string_literal: true

require 'rails_helper'

describe ArtService::Reports::CohortBuilder do
  # Set User.current and Location.current before any tests or let blocks
  before(:all) do
    User.current = User.first
    Location.current = Location.first
    @default_provider = Person.first
  end

  let(:start_date) { Date.parse('2026-02-01') }
  let(:end_date) { Date.parse('2026-02-28') }
  let(:program) { Program.find_by_name!('HIV PROGRAM') }
  let(:location) { Location.current }
  let(:provider) { @default_provider }

  before(:each) do
    # Ensure User.current remains set
    User.current ||= User.first
    Location.current ||= Location.first
  end

  # Concepts
  let(:arv_concept) { ConceptName.find_by_name!('Antiretroviral drugs').concept }
  let(:pregnant_concept) { ConceptName.find_by_name('Is patient pregnant?')&.concept }
  let(:reason_for_art_concept) { ConceptName.find_by_name('Reason for ART eligibility').concept }
  let(:on_arvs_state) do
    ProgramWorkflowState.where(concept: ConceptName.find_by_name('On antiretrovirals').concept).first
  end

  # Core encounter types
  let(:hiv_clinic_registration) { EncounterType.find_by_name!('HIV CLINIC REGISTRATION') }
  let(:hiv_staging) { EncounterType.find_by_name!('HIV STAGING') }
  let(:dispensing) { EncounterType.find_by_name!('DISPENSING') }
  let(:hiv_clinic_consultation) { EncounterType.find_by_name!('HIV CLINIC CONSULTATION') }

  let(:cohort_builder) { described_class.new }
  let(:cohort_struct) { OpenStruct.new }

  before(:each) do
    # Clean database records from previous tests
    PatientState.delete_all
    PatientProgram.delete_all
    Observation.delete_all
    DrugOrder.delete_all
    Order.delete_all
    Encounter.delete_all

    # Clean ALL temp tables that might exist from previous runs
    temp_tables = %w[
      temp_earliest_start_date
      temp_patient_outcomes
      temp_patient_outcomes_start
      temp_order_details
      temp_register_start_date
      temp_other_patient_types
      temp_pregnant_obs
      temp_cohort_members
      temp_art_start_date
      temp_patient_tb_status
      temp_latest_tb_status
      tmp_max_adherence
      temp_patient_side_effects
      temp_max_drug_orders
      temp_max_drug_orders_start
    ]

    temp_tables.each do |table|
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{table}")
    end
  end

  # Helper method to create the required "Reason for ART eligibility" observation
  def create_reason_for_art_obs(patient:, encounter:, date:)
    Observation.create!(
      person_id: patient.patient_id,
      concept_id: reason_for_art_concept.concept_id,
      value_coded: 19_477, # Valid reason concept ID
      obs_datetime: date,
      encounter: encounter,
      location_id: location.location_id
    )
  end

  describe '#build' do
    context 'with no patients' do
      it 'returns zero for all indicators' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)

        expect(result.total_registered.count).to eq(0)
        expect(result.initiated_on_art_first_time.count).to eq(0)
        expect(result.all_males.count).to eq(0)
        expect(result.total_alive_and_on_art.to_a).to eq([])
      end
    end

    context 'with a male patient initiated in the reporting period' do
      let!(:patient) do
        person = create(:person, gender: 'M', birthdate: 30.years.ago)
        create(:patient, patient_id: person.person_id)
      end

      let!(:patient_program) do
        PatientProgram.create!(
          patient: patient,
          program: program,
          location_id: location.location_id,
          date_enrolled: start_date + 5.days
        )
      end

      let!(:patient_state) do
        PatientState.create!(
          patient_program: patient_program,
          state: on_arvs_state.program_workflow_state_id,
          start_date: start_date + 5.days
        )
      end

      let!(:registration_encounter) do
        Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_clinic_registration,
          encounter_datetime: start_date + 5.days,
          location_id: location.location_id,
          provider_id: provider.person_id
        )
      end

      let!(:reason_for_art_obs) do
        create_reason_for_art_obs(patient: patient, encounter: registration_encounter, date: start_date + 5.days)
      end

      let!(:drug) do
        Drug.arv_drugs.first
      end

      let!(:order_type) { OrderType.find_by_name!('Drug order') }

      let!(:arv_order) do
        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 5.days,
          auto_expire_date: start_date + 35.days,
          encounter: registration_encounter,
          provider: User.first,
          orderer: User.first.user_id
        )

        DrugOrder.create!(
          order_id: order.order_id,
          drug_inventory_id: drug.drug_id,
          quantity: 60,
          equivalent_daily_dose: 2
        )

        order
      end

      it 'counts the patient in total_registered' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.total_registered.count).to eq(1)
      end

      it 'counts the patient in initiated_on_art_first_time' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.initiated_on_art_first_time.count).to eq(1)
      end

      it 'counts the patient in all_males' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.all_males.count).to eq(1)
      end

      it 'counts the patient as adult (15+)' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.adults_at_art_initiation.count).to eq(1)
      end

      it 'includes patient in alive_and_on_art' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.total_alive_and_on_art).to include(a_hash_including('patient_id' => patient.patient_id))
      end
    end

    context 'with a pregnant female patient' do
      let!(:patient) do
        person = create(:person, gender: 'F', birthdate: 25.years.ago)
        create(:patient, patient_id: person.person_id)
      end

      let!(:patient_program) do
        PatientProgram.create!(
          patient: patient,
          program: program,
          location_id: location.location_id,
          date_enrolled: start_date + 10.days
        )
      end

      let!(:patient_state) do
        PatientState.create!(
          patient_program: patient_program,
          state: on_arvs_state.program_workflow_state_id,
          start_date: start_date + 10.days
        )
      end

      let!(:registration_encounter) do
        Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_clinic_registration,
          encounter_datetime: start_date + 10.days,
          location_id: location.location_id,
          provider_id: provider.person_id
        )
      end

      let!(:reason_for_art_obs) do
        create_reason_for_art_obs(patient: patient, encounter: registration_encounter, date: start_date + 10.days)
      end
      let!(:pregnant_observation) do
        if pregnant_concept
          Observation.create!(
            person: patient.person,
            encounter: registration_encounter,
            concept: pregnant_concept,
            value_coded: ConceptName.find_by_name('Yes').concept_id,
            obs_datetime: start_date + 10.days
          )
        end
      end

      let!(:drug) do
        Drug.arv_drugs.first
      end

      let!(:order_type) { OrderType.find_by_name!('Drug order') }

      let!(:arv_order) do
        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 10.days,
          auto_expire_date: start_date + 40.days,
          encounter: registration_encounter,
          provider: User.first,
          orderer: User.first.user_id
        )

        DrugOrder.create!(
          order_id: order.order_id,
          drug_inventory_id: drug.drug_id,
          quantity: 60,
          equivalent_daily_dose: 2
        )

        order
      end

      it 'counts the patient in total_registered' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.total_registered.count).to eq(1)
      end

      it 'does not count the patient in all_males' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.all_males.count).to eq(0)
      end

      it 'counts the patient in pregnant_females_all_ages if observations exist' do
        skip 'Pregnant concept not found in test DB' unless pregnant_concept
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.pregnant_females_all_ages.count).to eq(1)
      end
    end

    context 'with a child patient under 24 months' do
      let!(:patient) do
        person = create(:person, gender: 'M', birthdate: 18.months.ago)
        create(:patient, patient_id: person.person_id)
      end

      let!(:patient_program) do
        PatientProgram.create!(
          patient: patient,
          program: program,
          location_id: location.location_id,
          date_enrolled: start_date + 3.days
        )
      end

      let!(:patient_state) do
        PatientState.create!(
          patient_program: patient_program,
          state: on_arvs_state.program_workflow_state_id,
          start_date: start_date + 3.days
        )
      end

      let!(:registration_encounter) do
        Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_clinic_registration,
          encounter_datetime: start_date + 3.days,
          location_id: location.location_id,
          provider_id: provider.person_id
        )
      end

      let!(:reason_for_art_obs) do
        create_reason_for_art_obs(patient: patient, encounter: registration_encounter, date: start_date + 3.days)
      end
      let!(:drug) do
        Drug.arv_drugs.first
      end

      let!(:order_type) { OrderType.find_by_name!('Drug order') }

      let!(:arv_order) do
        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 3.days,
          auto_expire_date: start_date + 33.days,
          encounter: registration_encounter,
          provider: User.first,
          orderer: User.first.user_id
        )

        DrugOrder.create!(
          order_id: order.order_id,
          drug_inventory_id: drug.drug_id,
          quantity: 30,
          equivalent_daily_dose: 2
        )

        order
      end

      it 'counts the patient in children_below_24_months_at_art_initiation' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.children_below_24_months_at_art_initiation.count).to eq(1)
      end

      it 'does not count in adults_at_art_initiation' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.adults_at_art_initiation.count).to eq(0)
      end
    end

    context 'with a child patient 24 months to 14 years' do
      let!(:patient) do
        person = create(:person, gender: 'F', birthdate: 5.years.ago)
        create(:patient, patient_id: person.person_id)
      end

      let!(:patient_program) do
        PatientProgram.create!(
          patient: patient,
          program: program,
          location_id: location.location_id,
          date_enrolled: start_date + 7.days
        )
      end

      let!(:patient_state) do
        PatientState.create!(
          patient_program: patient_program,
          state: on_arvs_state.program_workflow_state_id,
          start_date: start_date + 7.days
        )
      end

      let!(:registration_encounter) do
        Encounter.create!(
          patient: patient,
          program: program,
          type: hiv_clinic_registration,
          encounter_datetime: start_date + 7.days,
          location_id: location.location_id,
          provider_id: provider.person_id
        )
      end

      let!(:reason_for_art_obs) do
        create_reason_for_art_obs(patient: patient, encounter: registration_encounter, date: start_date + 7.days)
      end
      let!(:drug) do
        Drug.arv_drugs.first
      end

      let!(:order_type) { OrderType.find_by_name!('Drug order') }

      let!(:arv_order) do
        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 7.days,
          auto_expire_date: start_date + 37.days,
          encounter: registration_encounter,
          provider: User.first,
          orderer: User.first.user_id
        )

        DrugOrder.create!(
          order_id: order.order_id,
          drug_inventory_id: drug.drug_id,
          quantity: 60,
          equivalent_daily_dose: 2
        )

        order
      end

      it 'counts the patient in children_24_months_14_years_at_art_initiation' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.children_24_months_14_years_at_art_initiation.count).to eq(1)
      end

      it 'does not count in children_below_24_months' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.children_below_24_months_at_art_initiation.count).to eq(0)
      end
    end

    context 'with multiple patients in different categories' do
      let!(:male_adult) do
        person = create(:person, gender: 'M', birthdate: 35.years.ago)
        create(:patient, patient_id: person.person_id)
      end

      let!(:female_adult) do
        person = create(:person, gender: 'F', birthdate: 28.years.ago)
        create(:patient, patient_id: person.person_id)
      end

      let!(:child) do
        person = create(:person, gender: 'M', birthdate: 3.years.ago)
        create(:patient, patient_id: person.person_id)
      end

      before do
        [male_adult, female_adult, child].each_with_index do |patient, index|
          patient_program = PatientProgram.create!(
            patient: patient,
            program: program,
            location_id: location.location_id,
            date_enrolled: start_date + (index + 1).days
          )

          PatientState.create!(
            patient_program: patient_program,
            state: on_arvs_state.program_workflow_state_id,
            start_date: start_date + (index + 1).days
          )

          encounter = Encounter.create!(
            patient: patient,
            program: program,
            type: hiv_clinic_registration,
            encounter_datetime: start_date + (index + 1).days,
            location_id: location.location_id,
            provider_id: provider.person_id
          )

          # Add required reason for ART observation
          create_reason_for_art_obs(patient: patient, encounter: encounter, date: start_date + (index + 1).days)

          drug = Drug.arv_drugs.first

          order_type = OrderType.find_by_name!('Drug order')

          order = Order.create!(
            order_type_id: order_type.order_type_id,
            concept_id: arv_concept.concept_id,
            patient: patient,
            start_date: start_date + (index + 1).days,
            auto_expire_date: start_date + (index + 31).days,
            encounter: encounter,
            provider: User.first,
            orderer: User.first.user_id
          )

          DrugOrder.create!(
            order_id: order.order_id,
            drug_inventory_id: drug.drug_id,
            quantity: 60,
            equivalent_daily_dose: 2
          )
        end
      end

      it 'counts all patients in total_registered' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.total_registered.count).to eq(3)
      end

      it 'correctly counts males' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.all_males.count).to eq(2) # male_adult and child
      end

      it 'correctly counts adults' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.adults_at_art_initiation.count).to eq(2) # male_adult and female_adult
      end

      it 'correctly counts children 24 months to 14 years' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.children_24_months_14_years_at_art_initiation.count).to eq(1) # child
      end
    end

    context 'edge cases' do
      context 'patient initiated before reporting period' do
        let!(:patient) do
          person = create(:person, gender: 'M', birthdate: 30.years.ago)
          create(:patient, patient_id: person.person_id)
        end

        let!(:patient_program) do
          PatientProgram.create!(
            patient: patient,
            program: program,
            location_id: location.location_id,
            date_enrolled: start_date - 100.days
          )
        end

        let!(:patient_state) do
          PatientState.create!(
            patient_program: patient_program,
            state: on_arvs_state.program_workflow_state_id,
            start_date: start_date - 100.days
          )
        end

        let!(:registration_encounter) do
          Encounter.create!(
            patient: patient,
            program: program,
            type: hiv_clinic_registration,
            encounter_datetime: start_date - 100.days,
            location_id: location.location_id,
            provider_id: provider.person_id
          )
        end

        let!(:reason_for_art_obs) do
          create_reason_for_art_obs(patient: patient, encounter: registration_encounter, date: start_date - 100.days)
        end
        let!(:drug) do
          Drug.arv_drugs.first
        end

        let!(:order_type) { OrderType.find_by_name!('Drug order') }

        let!(:arv_order) do
          order = Order.create!(
            order_type_id: order_type.order_type_id,
            concept_id: arv_concept.concept_id,
            patient: patient,
            start_date: start_date - 100.days,
            auto_expire_date: end_date + 10.days, # Extend into reporting period so patient is active
            encounter: registration_encounter,
            provider: User.first,
            orderer: User.first.user_id
          )

          order
        end

        # Add a dispensing encounter BEFORE the reporting period
        let!(:dispensing_encounter) do
          Encounter.create!(
            patient: patient,
            program: program,
            type: dispensing,
            encounter_datetime: start_date - 50.days,
            location_id: location.location_id,
            provider_id: provider.person_id
          )
        end

        let!(:dispensing_order) do
          order = Order.create!(
            order_type_id: order_type.order_type_id,
            concept_id: arv_concept.concept_id,
            patient: patient,
            start_date: start_date - 50.days,
            auto_expire_date: start_date - 20.days,
            encounter: dispensing_encounter,
            provider: User.first,
            orderer: User.first.user_id
          )

          DrugOrder.create!(
            order_id: order.order_id,
            drug_inventory_id: drug.drug_id,
            quantity: 60,
            equivalent_daily_dose: 2
          )

          order
        end

        it 'does not count in initiated_on_art_first_time (quarterly)' do
          result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
          expect(result.initiated_on_art_first_time.count).to eq(0)
        end

        it 'counts in cumulative initiated_on_art_first_time' do
          result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
          expect(result.cum_initiated_on_art_first_time.count).to be >= 1
        end

        it 'is included in alive_and_on_art if still active' do
          result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
          expect(result.total_alive_and_on_art).to include(a_hash_including('patient_id' => patient.patient_id))
        end
      end

      context 'patient without ARV orders' do
        let!(:patient) do
          person = create(:person, gender: 'F', birthdate: 25.years.ago)
          create(:patient, patient_id: person.person_id)
        end

        let!(:patient_program) do
          PatientProgram.create!(
            patient: patient,
            program: program,
            location_id: location.location_id,
            date_enrolled: start_date + 5.days
          )
        end

        let!(:patient_state) do
          PatientState.create!(
            patient_program: patient_program,
            state: on_arvs_state.program_workflow_state_id,
            start_date: start_date + 5.days
          )
        end

        it 'should not be counted in indicators requiring ARV orders' do
          result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
          # Patient has state but no ARV orders, so shouldn't count
          expect(result.initiated_on_art_first_time.count).to eq(0)
        end
      end
    end
  end

  describe 'temporary table initialization' do
    it 'creates temp_earliest_start_date table' do
      cohort_builder.build(cohort_struct, start_date, end_date, nil)

      result = ActiveRecord::Base.connection.execute(
        "SHOW TABLES LIKE 'temp_earliest_start_date'"
      )
      expect(result.count).to eq(1)
    end

    it 'creates temp_patient_outcomes table' do
      cohort_builder.build(cohort_struct, start_date, end_date, nil)

      result = ActiveRecord::Base.connection.execute(
        "SHOW TABLES LIKE 'temp_patient_outcomes'"
      )
      expect(result.count).to eq(1)
    end
  end

  describe 'cumulative vs quarterly calculations' do
    let!(:old_patient) do
      person = create(:person, gender: 'M', birthdate: 40.years.ago)
      patient = create(:patient, patient_id: person.person_id)

      patient_program = PatientProgram.create!(
        patient: patient,
        program: program,
        location_id: location.location_id,
        date_enrolled: start_date - 200.days
      )

      PatientState.create!(
        patient_program: patient_program,
        state: on_arvs_state.program_workflow_state_id,
        start_date: start_date - 200.days
      )

      encounter = Encounter.create!(
        patient: patient,
        program: program,
        type: hiv_clinic_registration,
        encounter_datetime: start_date - 200.days,
        location_id: location.location_id,
        provider_id: provider.person_id
      )

      # Add required reason for ART observation
      create_reason_for_art_obs(patient: patient, encounter: encounter, date: start_date - 200.days)

      drug = Drug.arv_drugs.first

      order_type = OrderType.find_by_name!('Drug order')

      order = Order.create!(
        order_type_id: order_type.order_type_id,
        concept_id: arv_concept.concept_id,
        patient: patient,
        start_date: start_date - 200.days,
        auto_expire_date: end_date + 10.days, # Extend into reporting period
        encounter: encounter,
        provider: User.first,
        orderer: User.first.user_id
      )

      DrugOrder.create!(
        order_id: order.order_id,
        drug_inventory_id: drug.drug_id,
        quantity: 60,
        equivalent_daily_dose: 2
      )

      patient
    end

    # Add a drug refill order during the reporting period for old_patient
    let!(:old_patient_refill) do
      enc = Encounter.create!(
        patient: old_patient,
        program: program,
        type: dispensing,
        encounter_datetime: start_date + 3.days,
        location_id: location.location_id,
        provider_id: provider.person_id
      )

      ord = Order.create!(
        order_type_id: OrderType.find_by_name!('Drug order').order_type_id,
        concept_id: arv_concept.concept_id,
        patient: old_patient,
        start_date: start_date + 3.days,
        auto_expire_date: end_date + 10.days,
        encounter: enc,
        provider: User.first,
        orderer: User.first.user_id
      )

      DrugOrder.create!(
        order_id: ord.order_id,
        drug_inventory_id: Drug.arv_drugs.first.drug_id,
        quantity: 60,
        equivalent_daily_dose: 2
      )

      ord
    end

    let!(:new_patient) do
      person = create(:person, gender: 'F', birthdate: 30.years.ago)
      patient = create(:patient, patient_id: person.person_id)

      patient_program = PatientProgram.create!(
        patient: patient,
        program: program,
        location_id: location.location_id,
        date_enrolled: start_date + 5.days
      )

      PatientState.create!(
        patient_program: patient_program,
        state: on_arvs_state.program_workflow_state_id,
        start_date: start_date + 5.days
      )

      encounter = Encounter.create!(
        patient: patient,
        program: program,
        type: hiv_clinic_registration,
        encounter_datetime: start_date + 5.days,
        location_id: location.location_id,
        provider_id: provider.person_id
      )

      # Add required reason for ART observation
      create_reason_for_art_obs(patient: patient, encounter: encounter, date: start_date + 5.days)

      drug = Drug.arv_drugs.first

      order_type = OrderType.find_by_name!('Drug order')

      order = Order.create!(
        order_type_id: order_type.order_type_id,
        concept_id: arv_concept.concept_id,
        patient: patient,
        start_date: start_date + 5.days,
        auto_expire_date: start_date + 35.days,
        encounter: encounter,
        provider: User.first,
        orderer: User.first.user_id
      )

      DrugOrder.create!(
        order_id: order.order_id,
        drug_inventory_id: drug.drug_id,
        quantity: 60,
        equivalent_daily_dose: 2
      )

      patient
    end

    it 'quarterly only counts patients initiated in current quarter' do
      result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
      expect(result.initiated_on_art_first_time.count).to eq(1) # only new_patient
    end

    it 'cumulative counts all patients ever initiated' do
      result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
      expect(result.cum_initiated_on_art_first_time.count).to be >= 2 # both patients
    end

    it 'both patients appear in alive_and_on_art' do
      result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
      patient_ids = result.total_alive_and_on_art.map { |p| p['patient_id'] }
      expect(patient_ids).to include(old_patient.patient_id, new_patient.patient_id)
    end
  end

  describe 'ARV drug detection via arv_drug view' do
    let!(:patient) do
      person = create(:person, gender: 'M', birthdate: 30.years.ago)
      create(:patient, patient_id: person.person_id)
    end

    let!(:patient_program) do
      PatientProgram.create!(
        patient: patient,
        program: program,
        location_id: location.location_id,
        date_enrolled: start_date + 5.days
      )
    end

    let!(:patient_state) do
      PatientState.create!(
        patient_program: patient_program,
        state: on_arvs_state.program_workflow_state_id,
        start_date: start_date + 5.days
      )
    end

    let!(:registration_encounter) do
      Encounter.create!(
        patient: patient,
        program: program,
        type: hiv_clinic_registration,
        encounter_datetime: start_date + 5.days,
        location_id: location.location_id,
        provider_id: provider.person_id
      )
    end

    let!(:reason_for_art_obs) do
      create_reason_for_art_obs(patient: patient, encounter: registration_encounter, date: start_date + 5.days)
    end
    context 'when drug is in arv_drug view' do
      let!(:arv_drug) do
        # Use existing ARV drug from seed data
        Drug.arv_drugs.first
      end

      let!(:arv_order) do
        order_type = OrderType.find_by_name!('Drug order')

        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 5.days,
          auto_expire_date: start_date + 35.days,
          encounter: registration_encounter,
          provider: User.first,
          orderer: User.first.user_id
        )

        DrugOrder.create!(
          order_id: order.order_id,
          drug_inventory_id: arv_drug.drug_id,
          quantity: 60,
          equivalent_daily_dose: 2
        )

        order
      end

      it 'recognizes patient as being on ARVs' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.initiated_on_art_first_time.count).to eq(1)
      end

      it 'includes patient in outcomes' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.total_alive_and_on_art.map { |p| p['patient_id'] }).to include(patient.patient_id)
      end
    end

    context 'when drug is NOT in arv_drug view' do
      let!(:non_arv_concept) do
        ConceptName.find_by_name('Paracetamol')&.concept ||
          Concept.create!(
            class_id: ConceptClass.find_by_name('Drug').concept_class_id,
            datatype_id: ConceptDatatype.find_by_name('N/A').concept_datatype_id,
            changed_by: 1
          ).tap do |c|
            ConceptName.create!(
              concept: c,
              name: 'Paracetamol',
              locale: 'en'
            )
          end
      end

      let!(:non_arv_drug) do
        # Use any non-ARV drug from database
        Drug.where.not(drug_id: Drug.arv_drugs.select(:drug_id)).first
      end

      let!(:non_arv_order) do
        order_type = OrderType.find_by_name!('Drug order')

        order = Order.create!(
          order_type_id: order_type.order_type_id,
          concept_id: non_arv_concept.concept_id,
          patient: patient,
          start_date: start_date + 5.days,
          auto_expire_date: start_date + 35.days,
          encounter: registration_encounter,
          provider: User.first,
          orderer: User.first.user_id
        )

        DrugOrder.create!(
          order_id: order.order_id,
          drug_inventory_id: non_arv_drug.drug_id,
          quantity: 30,
          equivalent_daily_dose: 2
        )

        order
      end

      it 'does not count patient as initiated on ART' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)
        expect(result.initiated_on_art_first_time.count).to eq(0)
      end
    end

    describe 'Comprehensive Indicator Coverage Smoke Test' do
      it 'generates all 106 expected indicators in the result structure' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)

        # Core registration indicators
        expect(result).to respond_to(:total_registered)
        expect(result).to respond_to(:initiated_on_art_first_time)
        expect(result).to respond_to(:re_initiated_on_art)
        expect(result).to respond_to(:transfer_in)

        # Demographics - Gender
        expect(result).to respond_to(:all_males)
        expect(result).to respond_to(:unknown_gender)
        expect(result).to respond_to(:males_initiated_on_art_first_time)

        # Demographics - Age categories
        expect(result).to respond_to(:children_below_24_months_at_art_initiation)
        expect(result).to respond_to(:children_24_months_14_years_at_art_initiation)
        expect(result).to respond_to(:adults_at_art_initiation)
        expect(result).to respond_to(:unknown_age)

        # Maternal status indicators
        expect(result).to respond_to(:pregnant_females_all_ages)
        expect(result).to respond_to(:non_pregnant_females)
        expect(result).to respond_to(:initial_pregnant_females_all_ages)
        expect(result).to respond_to(:initial_non_pregnant_females_all_ages)
        expect(result).to respond_to(:total_pregnant_women)
        expect(result).to respond_to(:total_breastfeeding_women)
        expect(result).to respond_to(:total_other_patients)

        # Reason for eligibility
        expect(result).to respond_to(:presumed_severe_hiv_disease_in_infants)
        expect(result).to respond_to(:confirmed_hiv_infection_in_infants_pcr)
        expect(result).to respond_to(:who_stage_two)
        expect(result).to respond_to(:who_stage_three)
        expect(result).to respond_to(:who_stage_four)
        expect(result).to respond_to(:breastfeeding_mothers)
        expect(result).to respond_to(:pregnant_women)
        expect(result).to respond_to(:asymptomatic)
        expect(result).to respond_to(:unknown_other_reason_outside_guidelines)
        expect(result).to respond_to(:children_12_59_months)

        # TB status indicators
        expect(result).to respond_to(:current_episode_of_tb)
        expect(result).to respond_to(:tb_within_the_last_two_years)
        expect(result).to respond_to(:no_tb)
        expect(result).to respond_to(:tb_not_suspected)
        expect(result).to respond_to(:tb_suspected)
        expect(result).to respond_to(:tb_confirmed_on_tb_treatment)
        expect(result).to respond_to(:tb_confirmed_currently_not_yet_on_tb_treatment)
        expect(result).to respond_to(:unknown_tb_status)

        # Opportunistic infections
        expect(result).to respond_to(:kaposis_sarcoma)

        # Patient outcomes
        expect(result).to respond_to(:died_within_the_1st_month_of_art_initiation)
        expect(result).to respond_to(:died_within_the_2nd_month_of_art_initiation)
        expect(result).to respond_to(:died_within_the_3rd_month_of_art_initiation)
        expect(result).to respond_to(:total_alive_and_on_art)

        # Side effects
        expect(result).to respond_to(:total_patients_with_side_effects)
        expect(result).to respond_to(:total_patients_without_side_effects)
        expect(result).to respond_to(:unknown_side_effects)

        # Adherence
        expect(result).to respond_to(:patients_with_0_6_doses_missed_at_their_last_visit)
        expect(result).to respond_to(:patients_with_7_plus_doses_missed_at_their_last_visit)
        expect(result).to respond_to(:patients_with_unknown_adhrence)

        # Preventive treatments
        expect(result).to respond_to(:total_patients_on_arvs_and_cpt)
        expect(result).to respond_to(:total_patients_on_arvs_and_ipt)
        expect(result).to respond_to(:newly_initiated_on_ipt)
        expect(result).to respond_to(:newly_initiated_on_3hp)

        # Additional services
        expect(result).to respond_to(:total_patients_on_family_planning)
        expect(result).to respond_to(:total_patients_with_screened_bp)

        # Cumulative variants (sample key ones)
        expect(result).to respond_to(:cum_total_registered)
        expect(result).to respond_to(:cum_initiated_on_art_first_time)
        expect(result).to respond_to(:cum_re_initiated_on_art)
        expect(result).to respond_to(:cum_transfer_in)
        expect(result).to respond_to(:cum_all_males)
        expect(result).to respond_to(:cum_males_initiated_on_art_first_time)
        expect(result).to respond_to(:cum_children_below_24_months_at_art_initiation)
        expect(result).to respond_to(:cum_children_24_months_14_years_at_art_initiation)
        expect(result).to respond_to(:cum_adults_at_art_initiation)
        expect(result).to respond_to(:cum_pregnant_females_all_ages)
        expect(result).to respond_to(:cum_non_pregnant_females)
        expect(result).to respond_to(:cum_initial_pregnant_females_all_ages)
        expect(result).to respond_to(:cum_initial_non_pregnant_females_all_ages)
        expect(result).to respond_to(:cum_unknown_age)
        expect(result).to respond_to(:cum_unknown_gender)
        expect(result).to respond_to(:cum_presumed_severe_hiv_disease_in_infants)
        expect(result).to respond_to(:cum_confirmed_hiv_infection_in_infants_pcr)
        expect(result).to respond_to(:cum_who_stage_two)
        expect(result).to respond_to(:cum_who_stage_three)
        expect(result).to respond_to(:cum_who_stage_four)
        expect(result).to respond_to(:cum_breastfeeding_mothers)
        expect(result).to respond_to(:cum_pregnant_women)
        expect(result).to respond_to(:cum_asymptomatic)
        expect(result).to respond_to(:cum_unknown_other_reason_outside_guidelines)
        expect(result).to respond_to(:cum_children_12_59_months)
        expect(result).to respond_to(:cum_current_episode_of_tb)
        expect(result).to respond_to(:cum_tb_within_the_last_two_years)
        expect(result).to respond_to(:cum_no_tb)
        expect(result).to respond_to(:cum_kaposis_sarcoma)

        # Quarterly variants (sample key ones)
        expect(result).to respond_to(:quarterly_total_registered)
        expect(result).to respond_to(:quarterly_initiated_on_art_first_time)
        expect(result).to respond_to(:quarterly_re_initiated_on_art)
        expect(result).to respond_to(:quarterly_transfer_in)
        expect(result).to respond_to(:quarterly_all_males)
        expect(result).to respond_to(:quarterly_children_below_24_months_at_art_initiation)
        expect(result).to respond_to(:quarterly_children_24_months_14_years_at_art_initiation)
        expect(result).to respond_to(:quarterly_adults_at_art_initiation)
        expect(result).to respond_to(:quarterly_pregnant_females_all_ages)
        expect(result).to respond_to(:quarterly_non_pregnant_females)
        expect(result).to respond_to(:quarterly_unknown_age)
        expect(result).to respond_to(:quarterly_presumed_severe_hiv_disease_in_infants)
        expect(result).to respond_to(:quarterly_confirmed_hiv_infection_in_infants_pcr)
        expect(result).to respond_to(:quarterly_who_stage_two)
        expect(result).to respond_to(:quarterly_who_stage_three)
        expect(result).to respond_to(:quarterly_who_stage_four)
        expect(result).to respond_to(:quarterly_breastfeeding_mothers)
        expect(result).to respond_to(:quarterly_pregnant_women)
        expect(result).to respond_to(:quarterly_asymptomatic)
        expect(result).to respond_to(:quarterly_unknown_other_reason_outside_guidelines)
        expect(result).to respond_to(:quarterly_children_12_59_months)
        expect(result).to respond_to(:quarterly_current_episode_of_tb)
        expect(result).to respond_to(:quarterly_tb_within_the_last_two_years)
        expect(result).to respond_to(:quarterly_no_tb)
        expect(result).to respond_to(:quarterly_kaposis_sarcoma)
      end

      it 'all indicator values are callable without errors' do
        result = cohort_builder.build(cohort_struct, start_date, end_date, nil)

        # Verify indicators return values (not just respond_to)
        # These should not raise errors when accessed
        expect { result.total_registered }.not_to raise_error
        expect { result.initiated_on_art_first_time }.not_to raise_error
        expect { result.all_males }.not_to raise_error
        expect { result.total_alive_and_on_art }.not_to raise_error
        expect { result.cum_total_registered }.not_to raise_error
        expect { result.quarterly_total_registered }.not_to raise_error
        expect { result.pregnant_females_all_ages }.not_to raise_error
        expect { result.non_pregnant_females }.not_to raise_error
        expect { result.who_stage_two }.not_to raise_error
        expect { result.current_episode_of_tb }.not_to raise_error
        expect { result.total_patients_with_side_effects }.not_to raise_error
        expect { result.patients_with_0_6_doses_missed_at_their_last_visit }.not_to raise_error
        expect { result.total_patients_on_arvs_and_cpt }.not_to raise_error
        expect { result.newly_initiated_on_ipt }.not_to raise_error
        expect { result.total_breastfeeding_women }.not_to raise_error
      end
    end
  end
end
