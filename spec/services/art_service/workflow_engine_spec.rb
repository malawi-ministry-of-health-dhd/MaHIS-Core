# frozen_string_literal: true

require 'rails_helper'

ACTIVITIES = 'ART adherence, Drug Dispensations, HIV clinic consultations,
              HIV first visits, HIV reception visits, HIV staging visits,
              Manage Appointments, Prescriptions, Vitals'

hiv_program_id = 1

describe ArtService::WorkflowEngine do
  let(:epoch) { Time.now }
  let(:art_program) { find_or_create_program('HIV Program') }
  let(:patient) { create :patient }
  let(:hiv_program_id) { art_program.program_id }
  let(:engine) do
    UserProperty.find_or_create_by(user: User.current, property: 'Activities') do |up|
      up.property_value = ACTIVITIES
    end
    ArtService::WorkflowEngine.new program: art_program,
                                   patient:,
                                   date: epoch
  end

  let(:no_activity_engine) do
    UserProperty.find_by(user: User.current, property: 'Activities')&.delete

    ArtService::WorkflowEngine.new program: art_program,
                                   patient:,
                                   date: epoch
  end

  before(:each) do
    setup_cohort_test_data
    ensure_workflow_encounter_types
    ensure_workflow_concepts
    ensure_arv_drug
  end

  after(:each) do
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS=0')
    UserProperty.where(user: User.current, property: 'Activities').destroy_all
    Observation.unscoped.delete_all
    Order.unscoped.delete_all
    DrugOrder.unscoped.delete_all
    Encounter.unscoped.delete_all
    PatientProgram.unscoped.delete_all
    PatientState.unscoped.delete_all
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS=1')
  end

  describe :next_encounter do
    it 'returns nil if no activity is enabled' do
      expect(engine.next_encounter).not_to be_nil
      expect(no_activity_engine.next_encounter).to be_nil
    end

    it 'returns HIV CLINIC REGISTRATION for patient not in ART programme' do
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV CLINIC REGISTRATION')
    end

    it 'returns HIV CLINIC REGISTRATION for new ART patient' do
      enroll_patient patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV CLINIC REGISTRATION')
    end

    it 'skips HIV CLINIC REGISTRATION for previously registered patient on new visit' do
      register_patient patient, epoch - 100.days
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV RECEPTION')
    end

    it 'skips HIV CLINIC REGISTRATION for Drug refill patients' do
      register_patient(patient, epoch - 100.days)
      record_patient_type(patient, Concept::DRUG_REFILL)
      expect(engine.next_encounter.name.upcase).to eq('HIV RECEPTION')
    end

    it 'returns HIV_RECEPTION after HIV CLINIC REGISTRATION' do
      register_patient patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV RECEPTION')
    end

    it 'starts with HIV_RECEPTION for visiting patients' do
      register_patient patient
      Observation.create(person: patient.person,
                         concept_id: ConceptName.find_by_name!('Type of patient').concept_id,
                         value_coded: ConceptName.find_by_name!('External consultation').concept_id)
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV RECEPTION')
    end

    it 'skips VITALS and returns HIV STAGING after HIV RECEIPTION without patient' do
      receive_patient patient, guardian_only: true
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV STAGING')
    end

    it 'skips VITALS when on FAST TRACK' do
      receive_patient patient, on_fast_track: true
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV STAGING')
    end

    it 'returns VITALS after HIV RECEPTION with patient' do
      receive_patient patient, guardian_only: false
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('VITALS')
    end

    it 'returns HIV_STAGING for patients with VITALS' do
      record_vitals patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV STAGING')
    end

    it 'skips HIV STAGING for patients who have undergone staging before' do
      record_vitals patient
      create :encounter, encounter_type: EncounterType.find_by_name!('HIV Staging').encounter_type_id,
                         encounter_datetime: epoch - 100.days,
                         patient_id: patient.patient_id,
                         program_id: hiv_program_id
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV CLINIC CONSULTATION')
    end

    it 'skips HIV STAGING for Drug refill patients' do
      record_patient_type(patient, Concept::DRUG_REFILL)
      record_vitals patient
      expect(engine.next_encounter.name.upcase).to eq(EncounterType::HIV_CLINIC_CONSULTATION)
    end

    it 'returns HIV CLINIC CONSULTATION for patients with HIV STAGING' do
      record_staging patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('HIV CLINIC CONSULTATION')
    end

    it 'skips HIV CLINIC CONSULTATION for patients on fast track' do
      staging = record_staging patient
      Observation.create person: patient.person, encounter: staging,
                         concept_id: ConceptName.find_by_name!('Fast').concept_id,
                         obs_datetime: Time.now,
                         value_coded: ConceptName.find_by_name!('Yes').concept_id
      prescribe_arv patient, epoch - 1000.days
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('ART ADHERENCE')
    end

    it 'skips ART ADHERENCE and returns TREATMENT for new patient after HIV CLINIC CONSULTATION' do
      record_hiv_clinic_consultation patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TREATMENT')
    end

    it 'returns ART ADHERENCE after HIV CLINIC CONSULTATION for patient with previously received medication' do
      record_hiv_clinic_consultation patient
      prescribe_arv patient, epoch - 1000.days
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('ART ADHERENCE')
    end

    it 'skips ART ADHERENCE for Drug refill patients' do
      record_patient_type(patient, Concept::DRUG_REFILL)
      record_hiv_clinic_consultation patient
      prescribe_arv patient, epoch - 1000.days
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TREATMENT')
    end

    it 'returns TREATMENT after ART ADHERENCE' do
      record_art_adherence patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('TREATMENT')
    end

    it 'terminates workflow for patients not getting any treatment' do
      record_art_adherence patient
      record_patient_not_receiving_treatment patient
      encounter_type = engine.next_encounter
      expect(encounter_type).to be_nil
    end

    it 'returns FAST TRACK ASSESMENT after TREATMENT' do
      record_treatment patient, assess_fast_track: true
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('FAST TRACK ASSESMENT')
    end

    it 'skips FAST TRACK ASSESSMENT for patients on fast track' do
      treatment = record_treatment patient, assess_fast_track: true
      Observation.create person: patient.person, encounter: treatment,
                         concept_id: ConceptName.find_by_name!('Fast').concept_id,
                         obs_datetime: Time.now,
                         value_coded: ConceptName.find_by_name!('Yes').concept_id
      expect(engine.next_encounter.name.upcase).to eq('DISPENSING')
    end

    it 'skips FAST TRACK ASSESSMENT for Drug refill patients' do
      record_patient_type(patient, Concept::DRUG_REFILL)
      record_treatment patient, assess_fast_track: true
      expect(engine.next_encounter.name.upcase).to eq('DISPENSING')
    end

    it 'returns DISPENSING after FAST TRACK ASSESMENT' do
      record_fast_track patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('DISPENSING')
    end

    it 'returns APPOINTMENT after DISPENSING' do
      record_dispensing patient
      encounter_type = engine.next_encounter
      expect(encounter_type.name.upcase).to eq('APPOINTMENT')
    end

    it 'returns nil after APPOINTMENT' do
      record_appointment patient
      encounter_type = engine.next_encounter
      expect(encounter_type).to be_nil
    end
  end

  describe '#dispensing_complete?' do
    let(:treatment_type) { EncounterType.find_by_name!('TREATMENT') }

    it 'ignores non-drug orders when completed drug orders are present' do
      treatment = create(:encounter, type: treatment_type, patient:, program_id: hiv_program_id)
      drug_order = instance_double(DrugOrder, amount_needed: 0)
      completed_order = instance_double(Order, drug_order:)
      non_drug_order = instance_double(Order, drug_order: nil)
      orders = instance_double(ActiveRecord::Associations::CollectionProxy)

      allow(Encounter).to receive(:where).and_return(
        instance_double(ActiveRecord::Relation, where: instance_double(ActiveRecord::Relation, last: treatment))
      )
      allow(treatment).to receive(:orders).and_return(orders)
      allow(orders).to receive(:includes).with(:drug_order).and_return([completed_order, non_drug_order])

      expect(engine.send(:dispensing_complete?)).to be(true)
    end

    it 'is incomplete when a prescription contains no drug orders' do
      treatment = create(:encounter, type: treatment_type, patient:, program_id: hiv_program_id)
      non_drug_order = instance_double(Order, drug_order: nil)
      orders = instance_double(ActiveRecord::Associations::CollectionProxy)

      allow(Encounter).to receive(:where).and_return(
        instance_double(ActiveRecord::Relation, where: instance_double(ActiveRecord::Relation, last: treatment))
      )
      allow(treatment).to receive(:orders).and_return(orders)
      allow(orders).to receive(:includes).with(:drug_order).and_return([non_drug_order])

      expect(engine.send(:dispensing_complete?)).to be(false)
    end
  end

  # Helper methods
  def enroll_patient(patient)
    create :patient_program, patient:,
                             program: art_program
  end

  def register_patient(patient, date = nil)
    date ||= Time.now
    enroll_patient patient
    create(:encounter, type: EncounterType.find_by!(name: EncounterType::HIV_CLINIC_REGISTRATION),
                       patient:,
                       date_created: date,
                       program_id: hiv_program_id)
  end

  def receive_patient(patient, guardian_only: false, on_fast_track: false)
    register_patient patient
    reception = create :encounter, type: EncounterType.find_by_name!('HIV RECEPTION'),
                                   patient:,
                                   program_id: hiv_program_id
    if guardian_only
      create :observation, concept_id: ConceptName.find_by_name!('PATIENT PRESENT').concept_id,
                           encounter: reception,
                           value_coded: ConceptName.find_by_name!('No').concept_id,
                           person: patient.person
    else
      create :observation, concept_id: ConceptName.find_by_name!('PATIENT PRESENT').concept_id,
                           encounter: reception,
                           value_coded: ConceptName.find_by_name!('Yes').concept_id,
                           person: patient.person
    end

    if on_fast_track
      create :observation, concept_id: ConceptName.find_by_name!('Fast').concept_id,
                           encounter: reception,
                           person: patient.person,
                           value_coded: ConceptName.find_by_name!('Yes').concept_id
    end

    create :observation, concept_id: ConceptName.joins(:concept).find_by_name!('Guardian present').concept_id,
                         encounter: reception,
                         value_coded: ConceptName.find_by_name!('Yes').concept_id,
                         person: patient.person

    reception
  end

  def record_vitals(patient)
    receive_patient patient, guardian_only: false

    encounter = create :encounter, type: EncounterType.find_by_name!('VITALS'),
                                   patient:,
                                   program_id: hiv_program_id

    create :observation, encounter:,
                         person_id: encounter.patient_id,
                         concept_id: ConceptName.find_by_name!('Weight').concept_id,
                         value_numeric: 50

    create :observation, encounter:,
                         person_id: encounter.patient_id,
                         concept_id: ConceptName.find_by_name!('Height (cm)').concept_id,
                         value_numeric: 50
  end

  def record_staging(patient)
    record_vitals patient
    create :encounter, type: EncounterType.find_by_name!('HIV STAGING'),
                       patient:,
                       program_id: hiv_program_id
  end

  def record_hiv_clinic_consultation(patient)
    record_staging patient
    create :encounter, type: EncounterType.find_by_name!('HIV CLINIC CONSULTATION'),
                       patient:,
                       program_id: hiv_program_id
  end

  def record_art_adherence(patient)
    record_hiv_clinic_consultation patient
    create :encounter, type: EncounterType.find_by_name!('ART ADHERENCE'),
                       patient:,
                       program_id: hiv_program_id
  end

  def record_treatment(patient, assess_fast_track: false)
    record_art_adherence patient
    encounter = create :encounter, type: EncounterType.find_by_name!('TREATMENT'),
                                   patient:,
                                   program_id: hiv_program_id

    arv = Drug.arv_drugs[0]
    order = create(:order, concept: arv.concept, patient:,
                           encounter:)
    create :drug_order, order:, drug: arv

    setup_fast_track_assessment(encounter, patient, assess_fast_track)

    encounter
  end

  def setup_fast_track_assessment(encounter, patient, assess_fast_track)
    assess_fast_track_answer = if assess_fast_track
                                 GlobalProperty.find_or_create_by(property: 'enable.fast.track', location_id: Location.current.location_id) do |gp|
                                   gp.property_value = 'true'
                                 end
                                 ConceptName.find_by_name!('Yes').concept_id
                               else
                                 ConceptName.find_by_name!('No').concept_id
                               end

    create :observation, concept_id: ConceptName.find_by_name!('Assess for fast track?').concept_id,
                         encounter:,
                         person: patient.person,
                         value_coded: assess_fast_track_answer
  end

  def record_fast_track(patient)
    record_treatment patient, assess_fast_track: true

    encounter = create :encounter, type: EncounterType.find_by_name!('FAST TRACK ASSESMENT'),
                                   patient:,
                                   program_id: hiv_program_id
    create :observation, concept_id: ConceptName.find_by_name!('Adult 18 years +').concept_id,
                         person: patient.person,
                         encounter:
  end

  def record_dispensing(patient)
    record_fast_track patient
    create :encounter, type: EncounterType.find_by_name!('DISPENSING'),
                       patient:,
                       program_id: hiv_program_id
  end

  def record_appointment(patient)
    record_dispensing patient
    create :encounter, type: EncounterType.find_by_name!('APPOINTMENT'),
                       patient:,
                       program_id: hiv_program_id
  end

  def prescribe_arv(patient, date = nil)
    date ||= Time.now

    create :observation, person: patient.person,
                         encounter: create(:encounter_dispensing, patient:, program_id: hiv_program_id),
                         concept_id: ConceptName.find_by_name!('AMOUNT DISPENSED').concept_id,
                         value_drug: Drug.arv_drugs[0].drug_id,
                         obs_datetime: date
  end

  def record_patient_not_receiving_treatment(patient)
    create :observation, person: patient.person,
                         encounter: create(:encounter_vitals, patient:, program_id: hiv_program_id),
                         concept_id: ConceptName.find_by_name!('Prescribe drugs').concept_id,
                         value_coded: ConceptName.find_by_name!('No').concept_id
  end

  def record_patient_type(patient, concept_name, date: nil)
    registration = patient.encounters
                          .joins(:type)
                          .merge(EncounterType.where(name: EncounterType::REGISTRATION))
                          .first
    registration ||= create(:encounter, patient:,
                                        program_id: hiv_program_id,
                                        encounter_datetime: date || Date.today,
                                        type: EncounterType.find_by!(name: EncounterType::REGISTRATION))

    Observation.create(person_id: patient.patient_id,
                       encounter: registration,
                       concept_id: ConceptName.find_by!(name: Concept::PATIENT_TYPE).concept_id,
                       value_coded: ConceptName.find_by!(name: concept_name).concept_id)
  end

  def find_or_create_program(name)
    Program.find_by_name(name) || Program.find_by_name('HIV PROGRAM') || create(:program, name: 'HIV PROGRAM', concept: find_or_create_concept('HIV PROGRAM'))
  end

  def find_or_create_encounter_type(name)
    EncounterType.find_by_name(name) || create(:encounter_type, name:)
  end

  def find_or_create_concept(name)
    ConceptName.find_by_name(name)&.concept || create(:concept).tap do |concept|
      create(:concept_name, concept:, name:)
    end
  end

  def ensure_workflow_encounter_types
    find_or_create_encounter_type('HIV RECEPTION')
    find_or_create_encounter_type('VITALS')
    find_or_create_encounter_type('SYMPTOM SCREENING')
    find_or_create_encounter_type('AHD SCREENING')
    find_or_create_encounter_type('HIV STAGING')
    find_or_create_encounter_type('HIV Staging')
    find_or_create_encounter_type('HIV CLINIC CONSULTATION')
    find_or_create_encounter_type('ART ADHERENCE')
    find_or_create_encounter_type('TREATMENT')
    find_or_create_encounter_type('FAST TRACK ASSESMENT')
    find_or_create_encounter_type('DISPENSING')
    find_or_create_encounter_type('APPOINTMENT')
  end

  def ensure_workflow_concepts
    find_or_create_concept('Patient present')
    find_or_create_concept('PATIENT PRESENT')
    find_or_create_concept('External consultation')
    find_or_create_concept('Guardian present')
    find_or_create_concept('Weight')
    find_or_create_concept('Height (cm)')
    find_or_create_concept('Fast')
    find_or_create_concept('Assess for fast track?')
    find_or_create_concept('Adult 18 years +')
    find_or_create_concept('AMOUNT DISPENSED')
    find_or_create_concept('Prescribe drugs')
    find_or_create_concept('Fast track visit')
    find_or_create_concept('Refer to ART clinician')
    find_or_create_concept('Medication orders')
    find_or_create_concept('Continue with AHD')
    find_or_create_concept('AHD Symptom')
  end

  def ensure_arv_drug
    arv_concept = find_or_create_concept('Antiretroviral drugs')
    dtg_concept = find_or_create_concept('Dolutegravir')
    ConceptSet.find_or_create_by!(set: arv_concept, concept: dtg_concept) do |membership|
      membership.creator = 1
      membership.date_created = Time.now
      membership.uuid = SecureRandom.uuid
    end

    return if Drug.where(concept: dtg_concept).exists?

    create(:drug, concept: dtg_concept, name: 'Dolutegravir (50mg tablet)')
  end
end
