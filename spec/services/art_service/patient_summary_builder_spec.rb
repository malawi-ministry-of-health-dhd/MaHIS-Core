# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::PatientSummaryBuilder do
  describe '#build' do
    it 'exposes a new ART registration start date, visits, and vitals for Mastercard and patient dashboard' do
      registration_date = Date.parse('2026-08-20')
      registration_time = registration_date.to_time.change(hour: 9)
      program = find_or_create_program('HIV Program')
      on_arvs_state = find_or_create_program_state(program, 'On antiretrovirals')
      patient = create(:patient)
      stub_art_summary_sql_functions(registration_date)

      patient_program = create(
        :patient_program,
        patient:,
        program:,
        date_enrolled: registration_date
      )
      create(
        :patient_state,
        patient_program:,
        state: on_arvs_state.program_workflow_state_id,
        start_date: registration_date
      )

      create(
        :encounter,
        patient:,
        program:,
        type: find_or_create_encounter_type('HIV CLINIC REGISTRATION'),
        encounter_datetime: registration_time
      )
      vitals_encounter = create(
        :encounter,
        patient:,
        program:,
        type: find_or_create_encounter_type('VITALS'),
        encounter_datetime: registration_time
      )
      create_numeric_observation(vitals_encounter, 'Weight (kg)', 70, registration_time)
      create_numeric_observation(vitals_encounter, 'Height (cm)', 170, registration_time)

      summary = described_class.new(patient.patient_id, as_of: registration_date).build
      visit = summary.dig('visits', registration_date.to_s)

      expect(summary['art_start_date']).to eq(registration_date.to_s)
      expect(summary['init_weight']).to eq(70)
      expect(summary['init_height']).to eq(170)
      expect(summary['current_weight']).to eq(70)
      expect(summary['current_height']).to eq(170)
      expect(summary['visits']).to include(registration_date.to_s)
      expect(visit).to include(
        'weight' => 70,
        'height' => 170,
        'hasHivClinicRegistration' => true,
        'hasVitals' => true
      )
    end
  end

  def create_numeric_observation(encounter, concept_name, value, datetime)
    create(
      :observation,
      encounter:,
      person: encounter.patient.person,
      concept: find_or_create_concept(concept_name),
      value_numeric: value,
      obs_datetime: datetime
    )
  end

  def stub_art_summary_sql_functions(registration_date)
    connection = ActiveRecord::Base.connection
    allow(connection).to receive(:select_one).and_wrap_original do |original, sql, *args|
      case sql
      when /date_antiretrovirals_started/
        { 'start_date' => registration_date.to_s }
      when /patient_outcome/
        { 'outcome' => nil }
      when /patient_current_regimen/
        { 'regimen' => nil }
      else
        original.call(sql, *args)
      end
    end
  end

  def find_or_create_program(name)
    Program.find_by_name(name) || create(:program, name:, concept: find_or_create_concept(name))
  end

  def find_or_create_program_state(program, name)
    concept = find_or_create_concept(name)
    existing_state = ProgramWorkflowState.joins(:program_workflow)
                                         .where(program_workflow: { program_id: program.program_id }, concept_id: concept.concept_id)
                                         .first
    return existing_state if existing_state

    workflow = program.program_workflows.first || ProgramWorkflow.create!(
      program:,
      concept: find_or_create_concept('Treatment Status'),
      creator: 1,
      date_created: Time.current,
      retired: false,
      uuid: SecureRandom.uuid
    )
    ProgramWorkflowState.create!(
      program_workflow: workflow,
      concept:,
      initial: false,
      terminal: false,
      creator: 1,
      date_created: Time.current,
      retired: false,
      uuid: SecureRandom.uuid
    )
  end

  def find_or_create_encounter_type(name)
    EncounterType.find_by_name(name) || create(:encounter_type, name:)
  end

  def find_or_create_concept(name)
    ConceptName.find_by_name(name)&.concept || create(:concept).tap do |concept|
      create(:concept_name, concept:, name:)
    end
  end
end
