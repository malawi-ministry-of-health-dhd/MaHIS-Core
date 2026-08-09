# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SavePatientRecordService do
  describe '#rebuild_all_observations' do
    it 'removes a stale encounter type when MySQL has no non-voided observations for it' do
      patient_data = {
        observations: [
          { encounter_type: 37, status: 'saved', obs: [{ encounter_id: 4821 }] },
          { encounter_type: 99, status: 'saved', obs: [{ encounter_id: 9001 }] }
        ]
      }.with_indifferent_access

      allow(BuildPatientRecordService).to receive(:build_all_observations)
        .with(33, [37])
        .and_return([])

      described_class.new.send(:rebuild_all_observations, 33, patient_data, [37])

      expect(patient_data[:observations].map { |group| group['encounter_type'] }).to eq([99])
    end

    it 'replaces the entire refreshed encounter type with authoritative MySQL data' do
      patient_data = {
        observations: [
          { encounter_type: '37', status: 'saved', obs: [{ encounter_id: 4821 }] },
          { encounter_type: 99, status: 'saved', obs: [{ encounter_id: 9001 }] }
        ]
      }.with_indifferent_access
      rebuilt_group = {
        encounter_type: 37,
        status: 'saved',
        obs: [{ encounter_id: 4822 }]
      }

      allow(BuildPatientRecordService).to receive(:build_all_observations)
        .with(33, [37])
        .and_return([rebuilt_group])

      described_class.new.send(:rebuild_all_observations, 33, patient_data, [37])

      refreshed_group = patient_data[:observations].find { |group| group['encounter_type'].to_s == '37' }
      expect(refreshed_group['obs'].map { |obs| obs['encounter_id'] }).to eq([4822])
      expect(patient_data[:observations].count { |group| group['encounter_type'].to_s == '37' }).to eq(1)
    end
  end

  describe '#patient_void_pending?' do
    it 'is true when a void reason is present' do
      record = { void_patient: { reason: 'Duplicate' } }.with_indifferent_access
      expect(described_class.new.send(:patient_void_pending?, record)).to be true
    end

    it 'is false when void_patient is absent' do
      expect(described_class.new.send(:patient_void_pending?, {}.with_indifferent_access)).to be false
    end

    it 'is false when the reason is blank' do
      record = { void_patient: { reason: '  ' } }.with_indifferent_access
      expect(described_class.new.send(:patient_void_pending?, record)).to be false
    end
  end
  describe '#legacy_dde_identifier_void_pending?' do
    it 'requires at least one nonblank legacy identifier value' do
      service = described_class.new

      expect(service.send(:legacy_dde_identifier_void_pending?, { voidLegacyDdeIdentifiers: [' OLD123 '] })).to be true
      expect(service.send(:legacy_dde_identifier_void_pending?, { voidLegacyDdeIdentifiers: [' '] })).to be false
      expect(service.send(:legacy_dde_identifier_void_pending?, {})).to be false
    end
  end

  describe '#finalize_voided_patient_record' do
    it 'builds a response from the CouchDB history base, clearing the pending void request' do
      service = described_class.new
      operation_results = {
        void_patient: PatientRecordService::OperationResult.new(success: true, errors: [])
      }
      allow(service).to receive(:resolve_history_base).and_return(
        { 'ID' => 'ABC123', 'observations' => [{ 'encounter_type' => 37 }] }
      )
      allow(service).to receive(:couchdb_configured?).and_return(false)

      record = { void_patient: { reason: 'Duplicate' } }.with_indifferent_access
      result = service.send(:finalize_voided_patient_record, 33, record, operation_results, 'synced')

      expect(result['patientID']).to eq(33)
      expect(result['sync_status']).to eq('synced')
      expect(result['void_patient']).to be_nil
      expect(result['voided']).to be true
      expect(result['observations']).to eq([{ 'encounter_type' => 37 }])
      expect(result['operation_errors']).to eq({})
    end

    it 'surfaces operation errors from other operations that ran alongside the void' do
      service = described_class.new
      operation_results = {
        void_patient: PatientRecordService::OperationResult.new(success: true, errors: []),
        void_encounters: PatientRecordService::OperationResult.new(success: false, errors: ['Encounter 1 not found'])
      }
      allow(service).to receive(:resolve_history_base).and_return({ 'ID' => 'ABC123' })
      allow(service).to receive(:couchdb_configured?).and_return(false)

      record = { void_patient: { reason: 'Duplicate' } }.with_indifferent_access
      result = service.send(:finalize_voided_patient_record, 33, record, operation_results, 'partial_failed')

      expect(result['operation_errors']).to eq({ 'void_encounters' => ['Encounter 1 not found'] })
    end

    it 'deletes the CouchDB document instead of upserting it when CouchDB is configured' do
      service = described_class.new
      operation_results = { void_patient: PatientRecordService::OperationResult.new(success: true, errors: []) }
      allow(service).to receive(:resolve_history_base).and_return({ 'ID' => 'ABC123' })
      allow(service).to receive(:couchdb_configured?).and_return(true)
      allow(service).to receive(:delete_from_couchdb).and_return(true)
      allow(service).to receive(:sync_to_couchdb)

      record = { void_patient: { reason: 'Duplicate' } }.with_indifferent_access
      result = service.send(:finalize_voided_patient_record, 33, record, operation_results, 'synced')

      expect(service).to have_received(:delete_from_couchdb).with('patients_records', 'ABC123')
      expect(service).not_to have_received(:sync_to_couchdb)
      expect(result['deleted_from_couchdb']).to be true
    end

    it 'falls back to upserting a voided flag when the CouchDB delete fails' do
      service = described_class.new
      operation_results = { void_patient: PatientRecordService::OperationResult.new(success: true, errors: []) }
      allow(service).to receive(:resolve_history_base).and_return({ 'ID' => 'ABC123' })
      allow(service).to receive(:couchdb_configured?).and_return(true)
      allow(service).to receive(:delete_from_couchdb).and_raise(StandardError, 'boom')
      allow(service).to receive(:sync_to_couchdb)

      record = { void_patient: { reason: 'Duplicate' } }.with_indifferent_access
      result = service.send(:finalize_voided_patient_record, 33, record, operation_results, 'synced')

      expect(service).to have_received(:sync_to_couchdb).with(hash_including('voided' => true), 'patients_records', 'ABC123')
      expect(result['deleted_from_couchdb']).to be_nil
    end
  end
end
