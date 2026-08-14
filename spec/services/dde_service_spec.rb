# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DdeService do
  it 'treats a blank successful document lookup as missing instead of creating another DDE person' do
    service = described_class.new(program: instance_double(Program))
    client = instance_double(DdeClient)
    allow(service).to receive(:dde_client).and_return(client)
    allow(client).to receive(:post).with('search_by_doc_id', doc_id: 'missing-doc').and_return([[], 200])

    expect do
      service.reassign_patient_npid('doc_id' => 'missing-doc')
    end.to raise_error(described_class::MissingRemotePatientError, /was not found/)
  end

  it 'reports missing local DDE demographics instead of crashing while building the payload' do
    service = described_class.new(program: instance_double(Program))
    person = instance_double(Person, names: [], addresses: [], gender: nil, birthdate: nil)
    patient = instance_double(Patient, id: 285_949, person:)

    expect do
      service.send(:openmrs_to_dde_patient, patient)
    end.to raise_error(
      UnprocessableEntityError,
      /Patient 285949 is missing required DDE demographics: given_name, family_name, gender, birthdate/
    )
  end
end
