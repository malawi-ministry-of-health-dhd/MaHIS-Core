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
      registration_date = '2026-08-20'
      record = {
        '_id' => document_id,
        'patientID' => patient_id.to_i,
        'art_summary' => {
          'art_start_date' => registration_date,
          'init_weight' => 70,
          'init_height' => 170,
          'visits' => {
            registration_date => {
              'weight' => 70,
              'height' => 170,
              'hasVitals' => true
            }
          }
        }
      }

      allow(described_class).to receive(:ensure_db_exists).and_return(true)
      allow(Patient).to receive(:unscoped).and_return(patient_scope)
      allow(patient_scope).to receive(:includes).with(:person).and_return(patient_scope)
      allow(patient_scope).to receive(:find_by).with(patient_id: patient_id).and_return(patient)
      allow(RestClient).to receive(:get)
        .with(described_class.couchdb_url('patients_records', document_id))
        .and_raise(RestClient::NotFound)
      allow(described_class).to receive(:build_patient_record).with(patient_id).and_return(record)

      expect(described_class).not_to receive(:find_patient_document_by_identifier)

      patient_record = described_class.get_patient_record(patient_id: patient_id)

      expect(patient_record).to eq(record)
      expect(patient_record.dig('art_summary', 'art_start_date')).to eq(registration_date)
      expect(patient_record.dig('art_summary', 'init_weight')).to eq(70)
      expect(patient_record.dig('art_summary', 'init_height')).to eq(170)
      expect(patient_record.dig('art_summary', 'visits', registration_date)).to include(
        'weight' => 70,
        'height' => 170,
        'hasVitals' => true
      )
    end

    it 'rebuilds and persists the full ART summary for local numeric patients' do
      patient_id = '20837'
      document_id = 'efbfe034-41d8-4e62-8bbf-3e3a29e68a7d'
      stale_record = {
        '_id' => document_id,
        '_rev' => '1-old',
        'patientID' => patient_id.to_i,
        'art_summary' => {
          'art_start_date' => nil,
          'visits' => {}
        }
      }
      latest_record = stale_record.deep_dup
      fresh_art_summary = {
        'art_start_date' => '2026-08-20',
        'init_weight' => 70,
        'init_height' => 170,
        'visits' => {
          '2026-08-20' => {
            'weight' => 70,
            'height' => 170
          }
        }
      }
      patient = instance_double(Patient, patient_id: patient_id.to_i)
      patient_scope = double('patient scope')
      summary_builder = instance_double(ArtService::PatientSummaryBuilder, build: fresh_art_summary)

      allow(described_class).to receive(:ensure_db_exists).and_return(true)
      allow(Patient).to receive(:unscoped).and_return(patient_scope)
      allow(patient_scope).to receive(:includes).with(:person).and_return(patient_scope)
      allow(patient_scope).to receive(:find_by).with(patient_id: patient_id).and_return(patient)
      allow(patient_scope).to receive(:find_by).with(patient_id: patient_id.to_i).and_return(patient)
      allow(PatientRecordIdentityService).to receive(:document_id).with(patient: patient).and_return(document_id)
      allow(ArtService::PatientSummaryBuilder).to receive(:new).with(patient_id.to_i).and_return(summary_builder)
      allow(RestClient).to receive(:get)
        .with(described_class.couchdb_url('patients_records', document_id))
        .and_return(
          instance_double(RestClient::Response, body: stale_record.to_json),
          instance_double(RestClient::Response, body: latest_record.to_json)
        )

      expect(described_class).to receive(:save_patient_record) do |record, saved_patient_id|
        expect(saved_patient_id).to eq(patient_id.to_i)
        expect(record['art_summary']).to eq(fresh_art_summary)
      end

      record = described_class.get_patient_record(patient_id: patient_id)

      expect(record['art_summary']).to eq(fresh_art_summary)
    end
  end
end
