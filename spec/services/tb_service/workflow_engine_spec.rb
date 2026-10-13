# frozen_string_literal: true

require 'rails_helper'

describe TbService::WorkflowEngine do
  include ModelUtils
  include ActiveSupport::Testing::TimeHelpers

  # The suite runs without transactional fixtures, roll back each example's records
  around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  # The engine works on visit days, pin the clock to midday so that a visit's
  # steps never straddle midnight nor land in the future
  around do |example|
    travel_to(Time.zone.local(2026, 3, 10, 12, 0, 0)) { example.run }
  end

  # Order of the steps a TB patient goes through on their first visit
  VISIT_STEPS = %i[screen record_hiv_status examine_through_lab order_lab record_positive_lab_result
                   receive_at_reception record_vitals register treat dispense book_appointment].freeze

  let(:epoch) { Time.now }
  let(:tb_program) { program 'TB PROGRAM' }
  let(:person) do
    Person.create(birthdate: '1995-01-01', gender: 'M')
  end
  let(:patient) { Patient.create(patient_id: person.person_id) }

  let(:engine) do
    TbService::WorkflowEngine.new program: tb_program,
                                  patient:,
                                  date: epoch
  end

  # TbMdrService loads DR-TB regimen definitions from db/data/ntp which are not
  # on this branch. These scenarios cover patients who are not on MDR treatment.
  let(:mdr_service) do
    instance_double(TbService::TbMdrService, patient_on_mdr_treatment?: false,
                                             get_regimen_status: { mdr_status: false })
  end

  before { allow(TbService::TbMdrService).to receive(:new).and_return(mdr_service) }

  describe :next_encounter do
    it 'returns TB_INITIAL for a patient not a TB suspect in the TB programme' do
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TB_INITIAL')
    end

    it 'returns TB_INITIAL for a new a TB suspect' do
      enroll_patient patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TB_INITIAL')
    end

    it 'returns UPDATE PREGNANCY STATUS for a screened woman of child bearing age' do
      person.update!(gender: 'F', birthdate: 30.years.ago.to_date)
      screen(at: epoch - 1.hour)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('UPDATE PREGNANCY STATUS')
    end

    it 'returns UPDATE HIV STATUS for a screened patient without an HIV status' do
      screen(at: epoch - 1.hour)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('UPDATE HIV STATUS')
    end

    it 'returns UPDATE HIV STATUS when last negative HIV status is at least 28 days old' do
      screen(at: epoch - 1.hour)
      record_hiv_status(at: epoch - 28.days)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('UPDATE HIV STATUS')
    end

    it 'returns EXAMINATION for a screened patient with an HIV status' do
      complete_steps_up_to(:record_hiv_status)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('EXAMINATION')
    end

    it 'returns LAB ORDERS after test procedure type Laboratory examinations' do
      complete_steps_up_to(:examine_through_lab)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('LAB ORDERS')
    end

    it 'returns DIAGNOSIS after test procedure type Clinical' do
      complete_steps_up_to(:record_hiv_status)
      examine(procedure: 'Clinical', at: epoch - 5.minutes)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('DIAGNOSIS')
    end

    it 'returns LAB RESULTS for a TB suspect with a pending Lab Order' do
      complete_steps_up_to(:order_lab)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('LAB RESULTS')
    end

    it 'returns TB RECEPTION after patient tests TB positive' do
      complete_steps_up_to(:record_positive_lab_result)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TB RECEPTION')
    end

    it 'returns VITALS after TB RECEPTION' do
      complete_steps_up_to(:receive_at_reception)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('VITALS')
    end

    it 'returns TB REGISTRATION after recording TB Vitals' do
      complete_steps_up_to(:record_vitals)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TB REGISTRATION')
    end

    it 'returns TREATMENT after TB REGISTRATION' do
      complete_steps_up_to(:register)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TREATMENT')
    end

    it 'returns DISPENSING for a TB patient prescribed treatment' do
      complete_steps_up_to(:treat)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('DISPENSING')
    end

    it 'returns APPOINTMENT for a TB patient after dispensation' do
      complete_steps_up_to(:dispense)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('APPOINTMENT')
    end

    it 'returns nil after APPOINTMENT' do
      complete_steps_up_to(:book_appointment)
      expect(engine.next_encounter).to be_nil
    end

    it 'returns nil for a patient transferred out' do
      complete_steps_up_to(:dispense)
      transfer_out(patient)
      expect(engine.next_encounter).to be_nil
    end

    it 'returns TB ADHERENCE for a follow up patient' do
      complete_steps_up_to(:book_appointment, visit_date: epoch - 1.day)
      receive_at_reception(at: epoch - 20.minutes)
      record_vitals(at: epoch - 10.minutes)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TB ADHERENCE')
    end

    it 'returns LAB ORDERS for a follow up patient due for a lab examination' do
      # Lab examinations are due between the 56th and 84th day of treatment
      complete_steps_up_to(:book_appointment, visit_date: epoch - 60.days)
      record_hiv_status(at: epoch - 1.hour)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('LAB ORDERS')
    end
  end

  # Helpers methods

  # Runs the patient through the VISIT_STEPS up to last_step, a few minutes apart
  # and ending just before visit_date.
  def complete_steps_up_to(last_step, visit_date: epoch)
    steps = VISIT_STEPS[0..VISIT_STEPS.index(last_step)]
    steps.each_with_index do |step, index|
      send(step, at: visit_date - (steps.size - index).minutes)
    end
  end

  def enroll_patient(patient)
    create :patient_program, patient:, program: tb_program,
                             location_id: Location.current.location_id
  end

  def record_obs(encounter_name, concept_name, at:, **value)
    encounter = create :encounter, type: encounter_type(encounter_name),
                                   patient:, program: tb_program, encounter_datetime: at
    create :observation, encounter:, person: patient.person, concept: concept(concept_name),
                         obs_datetime: at, **value
  end

  def screen(at:)
    enroll_patient patient
    record_obs('TB_INITIAL', 'Type of patient', at:, value_coded: concept('New patient').concept_id)
  end

  def record_hiv_status(at:)
    record_obs('UPDATE HIV STATUS', 'HIV status', at:, value_coded: concept('Negative').concept_id)
  end

  def examine(procedure:, at:)
    record_obs('EXAMINATION', 'Procedure type', at:, value_coded: concept(procedure).concept_id)
  end

  def examine_through_lab(at:)
    examine(procedure: 'Laboratory examinations', at:)
  end

  def order_lab(at:)
    record_obs('LAB ORDERS', 'Test type', at:, value_coded: concept('Tuberculous').concept_id)
  end

  def record_positive_lab_result(at:)
    record_obs('LAB RESULTS', 'TB status', at:, value_coded: concept('Positive').concept_id)
  end

  def receive_at_reception(at:)
    record_obs('TB RECEPTION', 'Patient lives or works near?', at:, value_coded: concept('Yes').concept_id)
  end

  def record_vitals(at:)
    create :encounter, type: encounter_type('VITALS'),
                       patient:, program: tb_program, encounter_datetime: at
  end

  def register(at:)
    record_obs('TB REGISTRATION', 'TB registration number', at:, value_text: 'TB/0001/2026')
  end

  def treat(at:)
    record_obs('TREATMENT', 'Medication orders', at:,
                                                 value_coded: concept('Rifampicin isoniazid and pyrazinamide').concept_id)
  end

  def dispense(at:)
    record_obs('DISPENSING', 'Amount dispensed', at:, value_numeric: 10)
  end

  def book_appointment(at:)
    record_obs('APPOINTMENT', 'Appointment date', at:, value_datetime: at + 14.days)
  end

  TRANSFERRED_OUT_STATE = 95

  def transfer_out(patient)
    patient_program = PatientProgram.find_by!(patient:, program: tb_program)
    PatientState.create!(patient_program:, state: TRANSFERRED_OUT_STATE, start_date: epoch.to_date)
  end
end
