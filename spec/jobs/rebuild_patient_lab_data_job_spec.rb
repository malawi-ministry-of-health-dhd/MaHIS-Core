# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RebuildPatientLabDataJob, type: :job do
  subject(:job) { described_class.new }

  describe '#update_couchdb_lab_orders' do
    let(:patient_id) { 123 }
    let(:document_id) { '4f489184-3ff1-49e0-b642-7fdbba21c818' }
    let(:doc_url) { "http://couchdb/patients_records/#{document_id}" }
    let(:lab_orders_data) { { 'saved' => [{ 'order_id' => 1 }], 'unsaved' => [] } }
    let(:patient_record) { { _id: document_id, patientID: patient_id, labOrders: lab_orders_data } }

    before do
      allow(job).to receive(:ensure_db_exists).with(described_class::PATIENTS_DB).and_return(true)
      allow(job).to receive(:couchdb_url)
        .with(described_class::PATIENTS_DB, URI.encode_www_form_component(document_id))
        .and_return(doc_url)
    end

    it 'rebuilds and syncs the full patient document when the lab-only document is missing' do
      allow(RestClient).to receive(:get).with(doc_url).and_raise(RestClient::NotFound)
      allow(BuildPatientRecordService).to receive(:build_patient_record).with(patient_id).and_return(patient_record)
      allow(PatientRecordIdentityService).to receive(:document_id).with(record: patient_record).and_return(document_id)

      expect(job).to receive(:sync_to_couchdb).with(patient_record.as_json, described_class::PATIENTS_DB, document_id)

      expect do
        job.send(:update_couchdb_lab_orders, document_id, lab_orders_data, patient_id)
      end.not_to raise_error
    end

    it 'raises when the rebuilt full patient document has a different document id' do
      allow(RestClient).to receive(:get).with(doc_url).and_raise(RestClient::NotFound)
      allow(BuildPatientRecordService).to receive(:build_patient_record).with(patient_id).and_return(patient_record)
      allow(PatientRecordIdentityService).to receive(:document_id).with(record: patient_record).and_return('different-id')

      expect(job).not_to receive(:sync_to_couchdb)

      expect do
        job.send(:update_couchdb_lab_orders, document_id, lab_orders_data, patient_id)
      end.to raise_error(/generated CouchDB document different-id; expected #{document_id}/)
    end
  end
end