# frozen_string_literal: true

require 'rails_helper'

describe ArtService::Reports::CohortBuilder, type: :service do
  include ModelUtils

  let(:start_date) { Date.parse('2026-02-01') }
  let(:end_date) { Date.parse('2026-02-28') }
  let(:program) { Program.find_by_name!('HIV Program') }
  let(:location) { Location.current }
  let(:provider) { Person.first }
  let(:arv_concept) { ConceptName.find_by_name!('Antiretroviral drugs').concept }
  let(:cohort_builder) { ArtService::Reports::CohortBuilder.new }
  let(:cohort_struct) { OpenStruct.new }

  # Each example builds the cohort once, the build is expensive
  let(:result) { cohort_builder.build(cohort_struct, start_date, end_date, nil) }

  # The cohort covers every patient at the current location, start each example
  # from a clean slate (same as cohort_builder_spec.rb)
  before do
    PatientState.unscoped.delete_all
    PatientProgram.unscoped.delete_all
    # Grouped observations reference their parent observation
    Observation.unscoped.where.not(obs_group_id: nil).update_all(obs_group_id: nil)
    Observation.unscoped.delete_all
    DrugOrder.unscoped.delete_all
    Order.unscoped.delete_all
    Encounter.unscoped.delete_all

    %w[
      temp_earliest_start_date temp_patient_outcomes temp_patient_outcomes_start temp_order_details
      temp_register_start_date temp_other_patient_types temp_pregnant_obs temp_cohort_members
      temp_art_start_date temp_patient_tb_status temp_latest_tb_status tmp_max_adherence
      temp_patient_side_effects temp_max_drug_orders temp_max_drug_orders_start
    ].each do |table|
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{table}_loc_#{location.location_id}")
    end
  end

  def patient_ids(rows)
    rows.to_a.map { |row| row.is_a?(Hash) ? row['patient_id'].to_i : row.to_i }
  end

  def create_encounter(patient, type, date)
    Encounter.create!(patient:, program:, type: EncounterType.find_by_name!(type), encounter_datetime: date,
                      location_id: location.location_id, provider_id: provider.person_id)
  end

  def record_obs(patient, encounter, concept_name, date, **value)
    Observation.create!(person: patient.person, encounter:, concept: concept(concept_name),
                        obs_datetime: date, location_id: location.location_id, **value)
  end

  def hiv_program_state(name)
    ProgramWorkflowState.joins(:program_workflow)
                        .where(program_workflow: { program_id: program.program_id })
                        .where(concept_id: ConceptName.where(name:).select(:concept_id))
                        .first!
  end

  # Registers a patient into the HIV programme and starts them on ARVs.
  # A month's supply of ARVs is prescribed on enrolment.
  def create_patient_on_art(gender: 'M', birthdate: 30.years.ago, enrolled_on: start_date + 5.days,
                            reason: 'WHO stage III adult')
    person = create(:person, gender:, birthdate:)
    patient = create(:patient, patient_id: person.person_id)

    patient_program = PatientProgram.create!(patient:, program:, location_id: location.location_id,
                                             date_enrolled: enrolled_on)
    PatientState.create!(patient_program:, state: hiv_program_state('On antiretrovirals').id,
                         start_date: enrolled_on)

    registration = create_encounter(patient, 'HIV CLINIC REGISTRATION', enrolled_on)
    record_obs(patient, registration, 'Reason for ART eligibility', enrolled_on,
               value_coded: concept(reason).concept_id)

    order = Order.create!(order_type_id: OrderType.find_by_name!('Drug order').order_type_id,
                          concept_id: arv_concept.concept_id, patient:, start_date: enrolled_on,
                          auto_expire_date: enrolled_on + 30.days, encounter: registration,
                          provider: User.current, orderer: User.current.user_id)
    DrugOrder.create!(order_id: order.order_id, drug_inventory_id: Drug.arv_drugs.first.drug_id,
                      quantity: 60, equivalent_daily_dose: 2)

    patient
  end

  def change_outcome(patient, state_name, date: end_date - 10.days)
    patient_program = PatientProgram.find_by!(patient:, program:)
    PatientState.create!(patient_program:, state: hiv_program_state(state_name).id, start_date: date)
  end

  describe 'WHO Stage indicators' do
    it 'counts a patient started on WHO stage 3 in who_stage_three only' do
      create_patient_on_art(reason: 'WHO stage III adult')

      expect(result.who_stage_three).to eq(1)
      expect(result.who_stage_four).to eq(0)
    end

    it 'counts a patient started on WHO stage 4 in who_stage_four only' do
      create_patient_on_art(gender: 'F', birthdate: 28.years.ago, reason: 'WHO stage IV adult')

      expect(result.who_stage_four).to eq(1)
      expect(result.who_stage_three).to eq(0)
    end

    it 'counts an asymptomatic patient in asymptomatic' do
      patient = create_patient_on_art(reason: 'Asymptomatic HIV infection')

      expect(patient_ids(result.asymptomatic)).to include(patient.patient_id)
      expect(result.who_stage_three).to eq(0)
    end
  end

  describe 'TB Status indicators' do
    def record_who_stage_criteria(patient, criteria)
      enrolled_on = start_date + 5.days
      staging = create_encounter(patient, 'HIV STAGING', enrolled_on)
      record_obs(patient, staging, 'Who stages criteria present', enrolled_on,
                 value_coded: concept(criteria).concept_id)
    end

    it 'counts a patient with a current episode of TB in current_episode_of_tb and not in no_tb' do
      patient = create_patient_on_art
      record_who_stage_criteria(patient, 'PULMONARY TUBERCULOSIS (CURRENT)')

      expect(patient_ids(result.current_episode_of_tb)).to include(patient.patient_id)
      expect(patient_ids(result.no_tb)).not_to include(patient.patient_id)
    end

    it 'counts a patient with TB in the last 2 years in tb_within_the_last_two_years' do
      patient = create_patient_on_art
      record_who_stage_criteria(patient, 'Pulmonary tuberculosis within the last 2 years')

      expect(patient_ids(result.tb_within_the_last_two_years)).to include(patient.patient_id)
      expect(patient_ids(result.current_episode_of_tb)).not_to include(patient.patient_id)
      expect(patient_ids(result.no_tb)).not_to include(patient.patient_id)
    end

    it 'counts a patient without TB in no_tb' do
      patient = create_patient_on_art

      expect(patient_ids(result.no_tb)).to include(patient.patient_id)
      expect(patient_ids(result.current_episode_of_tb)).to be_empty
    end
  end

  describe 'Outcome indicators' do
    let(:enrolled_on) { start_date - 50.days }

    it 'counts a patient with drugs in hand as alive and on ART' do
      # Prescribed 2026-02-10, a month's supply has not run out by the end of February
      patient = create_patient_on_art(enrolled_on: start_date + 9.days)

      expect(patient_ids(result.total_alive_and_on_art)).to include(patient.patient_id)
      expect(patient_ids(result.died_total)).not_to include(patient.patient_id)
    end

    it 'counts a patient who died in died_total' do
      patient = create_patient_on_art(enrolled_on:)
      change_outcome(patient, 'Patient died')

      expect(patient_ids(result.died_total)).to include(patient.patient_id)
      expect(patient_ids(result.total_alive_and_on_art)).not_to include(patient.patient_id)
    end

    it 'counts a patient whose drugs ran out long ago as defaulted' do
      patient = create_patient_on_art(enrolled_on: start_date - 200.days)

      expect(patient_ids(result.defaulted)).to include(patient.patient_id)
      expect(patient_ids(result.total_alive_and_on_art)).not_to include(patient.patient_id)
    end

    it 'counts a patient who transferred out in transfered_out' do
      patient = create_patient_on_art(enrolled_on:)
      change_outcome(patient, 'Patient transferred out')

      expect(patient_ids(result.transfered_out)).to include(patient.patient_id)
      expect(patient_ids(result.total_alive_and_on_art)).not_to include(patient.patient_id)
    end

    it 'counts a patient who stopped treatment in stopped_art' do
      patient = create_patient_on_art(enrolled_on:)
      change_outcome(patient, 'Treatment stopped')

      expect(patient_ids(result.stopped_art)).to include(patient.patient_id)
      expect(patient_ids(result.total_alive_and_on_art)).not_to include(patient.patient_id)
    end
  end

  describe 'Transfer and Re-initiation' do
    it 'counts a patient who started ART at another facility in transfer_in' do
      patient = create_patient_on_art(gender: 'F', birthdate: 32.years.ago, enrolled_on: start_date + 10.days)
      registration = Encounter.find_by!(patient:, type: EncounterType.find_by_name!('HIV CLINIC REGISTRATION'))
      record_obs(patient, registration, 'Date antiretrovirals started', start_date + 10.days,
                 value_datetime: start_date - 1.year)

      expect(patient_ids(result.transfer_in)).to include(patient.patient_id)
      expect(patient_ids(result.re_initiated_on_art)).not_to include(patient.patient_id)
      expect(patient_ids(result.initiated_on_art_first_time)).not_to include(patient.patient_id)
    end
  end
end
