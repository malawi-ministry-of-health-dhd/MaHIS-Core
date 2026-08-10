# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CouchdbPatientService do
  describe '.get_patient_record' do
    it 'accepts a CouchDB document identifier as well as a numeric patient id' do
      document_id = 'P1113400006543'
      record = { '_id' => document_id, 'patientID' => 20_837, 'personInformation' => { 'given_name' => 'Test' } }

      allow(described_class).to receive(:ensure_db_exists).and_return(true)
      allow(PatientIdentifier).to receive_message_chain(:unscoped, :where, :pick).and_return(nil)
      allow(RestClient).to receive(:get)
        .with(described_class.couchdb_url('patients_records', document_id))
        .and_return(instance_double(RestClient::Response, body: record.to_json))

      expect(described_class.get_patient_record(patient_id: document_id)).to eq(record)
    end

    it 'builds a newly registered local patient without scanning legacy identifiers' do
      patient_id = '641113'
      document_id = 'efbfe034-41d8-4e62-8bbf-3e3a29e68a7d'
      person = instance_double(Person, uuid: document_id)
      patient = instance_double(Patient, person: person)
      patient_scope = double('patient scope')
      record = { '_id' => document_id, 'patientID' => patient_id.to_i }

      allow(described_class).to receive(:ensure_db_exists).and_return(true)
      allow(Patient).to receive(:unscoped).and_return(patient_scope)
      allow(patient_scope).to receive(:includes).with(:person).and_return(patient_scope)
      allow(patient_scope).to receive(:find_by).with(patient_id: patient_id).and_return(patient)
      allow(RestClient).to receive(:get)
        .with(described_class.couchdb_url('patients_records', document_id))
        .and_raise(RestClient::NotFound)
      allow(described_class).to receive(:build_patient_record).with(patient_id).and_return(record)

      expect(described_class).not_to receive(:find_patient_document_by_identifier)

      expect(described_class.get_patient_record(patient_id: patient_id)).to eq(record)
    end
  end
end
