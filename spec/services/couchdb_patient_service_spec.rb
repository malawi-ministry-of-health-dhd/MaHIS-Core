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
  end
end
