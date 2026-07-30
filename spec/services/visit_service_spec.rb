# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VisitService do
  OPD_PROGRAM_ID = 14
  HTS_PROGRAM_ID = 38

  before do
    @location_id = User.current&.location_id || Location.current&.location_id || 700
    @user_id = User.current&.user_id || 1
    @patient = create_patient_with_identifier
  end

  after do
    if @patient
      Stage.where(patient_id: @patient.patient_id).delete_all
      Visit.where(patient_id: @patient.patient_id).delete_all
      PatientIdentifier.where(patient_id: @patient.patient_id).delete_all
      Patient.where(patient_id: @patient.patient_id).delete_all
      Person.where(person_id: @patient.patient_id).delete_all
    end
  end

  it 'closes the supplied HTS visit without closing the active OPD visit' do
    opd_visit = create_open_visit(OPD_PROGRAM_ID)
    hts_visit = create_open_visit(HTS_PROGRAM_ID)
    opd_stage = create_stage(opd_visit, 'CONSULTATION', OPD_PROGRAM_ID)
    hts_stage = create_stage(hts_visit, 'HTS', HTS_PROGRAM_ID)

    described_class.new.close_visit(
      identifier: @identifier,
      visit_id: hts_visit.visit_id,
      program_id: HTS_PROGRAM_ID,
      location_id: @location_id
    )

    expect(hts_visit.reload.date_stopped).to be_present
    expect(opd_visit.reload.date_stopped).to be_nil
    expect(Stage.exists?(hts_stage.id)).to be(false)
    expect(Stage.exists?(opd_stage.id)).to be(true)
  end

  it 'uses program_id to choose the visit when no visit_id is supplied' do
    opd_visit = create_open_visit(OPD_PROGRAM_ID)
    hts_visit = create_open_visit(HTS_PROGRAM_ID)

    described_class.new.close_visit(
      identifier: @identifier,
      program_id: HTS_PROGRAM_ID,
      location_id: @location_id
    )

    expect(hts_visit.reload.date_stopped).to be_present
    expect(opd_visit.reload.date_stopped).to be_nil
  end

  it "uses the authenticated user's location when creating a visit" do
    stale_patient_location_id = @location_id.to_i + 1

    data = described_class.new.create_visit(
      patient_id: @patient.patient_id,
      identifier: @identifier,
      visit_type_id: visit_type.visit_type_id,
      date_started: Time.current,
      provider_id: @user_id,
      program_id: OPD_PROGRAM_ID,
      location_id: stale_patient_location_id
    )

    expect(Visit.find(data['visit_id']).location_id).to eq(@location_id)
    expect(data[:location_id]).to eq(@location_id.to_s)
  end

  it "uses the authenticated user's location when creating a stage" do
    visit = create_open_visit(OPD_PROGRAM_ID)
    stale_patient_location_id = @location_id.to_i + 1

    data = StagesService.new.create_stage(
      patient_id: @patient.patient_id,
      identifier: @identifier,
      stage: 'VITALS',
      program_id: OPD_PROGRAM_ID,
      location_id: stale_patient_location_id
    )

    expect(Stage.find(data[:id]).location_id).to eq(@location_id)
    expect(data[:location_id]).to eq(@location_id.to_s)
    expect(data[:visit_id]).to eq(visit.visit_id)
  end

  private

  def create_patient_with_identifier
    ensure_identifier_type
    person = Person.create!(
      gender: 'F',
      birthdate: Date.parse('1990-01-01'),
      birthdate_estimated: 0,
      creator: @user_id,
      date_created: Time.current,
      voided: 0,
      uuid: SecureRandom.uuid
    )
    patient = Patient.create!(patient_id: person.person_id, creator: @user_id)
    @identifier = "HTS-#{SecureRandom.hex(6)}"

    PatientIdentifier.create!(
      patient_id: patient.patient_id,
      identifier: @identifier,
      identifier_type: 3,
      location_id: @location_id,
      creator: @user_id,
      date_created: Time.current,
      preferred: 1,
      voided: 0,
      uuid: SecureRandom.uuid
    )

    patient
  end

  def ensure_identifier_type
    return if PatientIdentifierType.unscoped.exists?(patient_identifier_type_id: 3)

    PatientIdentifierType.unscoped.create!(
      patient_identifier_type_id: 3,
      name: 'National id',
      description: 'National id',
      creator: @user_id,
      date_created: Time.current,
      retired: false,
      uuid: SecureRandom.uuid
    )
  end

  def visit_type
    @visit_type ||= VisitType.unscoped.find_by(visit_type_id: 1) ||
                    VisitType.unscoped.create!(
                      visit_type_id: 1,
                      name: 'Initial',
                      creator: @user_id,
                      date_created: Time.current,
                      retired: false,
                      uuid: SecureRandom.uuid
                    )
  end

  def create_open_visit(program_id)
    Visit.create!(
      patient_id: @patient.patient_id,
      visit_type_id: visit_type.visit_type_id,
      date_started: Time.current,
      date_created: Time.current,
      creator: @user_id,
      voided: false,
      location_id: @location_id,
      program_id: program_id
    )
  end

  def create_stage(visit, stage, program_id)
    Stage.create!(
      patient_id: @patient.patient_id,
      visit_id: visit.visit_id,
      location_id: @location_id,
      status: true,
      arrival_time: Time.current,
      stage: stage,
      program_id: program_id
    )
  end
end
