# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::PatientIdentityManager do
  subject(:manager) { described_class.new }

  describe '#save_person_information' do
    it 'recovers the canonical patient from the primary identifier when patientID is stale' do
      patient = create(:patient)
      identifier = "TEST-MAHIS-#{SecureRandom.hex(6)}"
      create(
        :patient_identifier,
        patient: patient,
        identifier: identifier,
        identifier_type: 3,
        voided: 0
      )
      record = { patientID: patient.patient_id + 1_000_000, ID: identifier }

      result = manager.save_person_information(record)

      expect(result).to include(patient_id: patient.patient_id, id: identifier)
      expect(record[:patientID]).to eq(patient.patient_id)
    end

    it 'rejects a phantom patientID when no patient or registration details can be resolved' do
      record = {
        patientID: 9_999_999_999,
        ID: "MISSING-MAHIS-#{SecureRandom.hex(6)}"
      }

      result = manager.save_person_information(record)

      expect(result[:patient_id]).to be_nil
      expect(result[:id]).to eq(record[:ID])
    end
  end

  describe '#void_legacy_dde_identifiers' do
    it 'voids only the requested active type-2 identifiers for the patient' do
      patient = create(:patient)
      requested = create(
        :patient_identifier,
        patient:,
        identifier: "OLD-#{SecureRandom.hex(5)}",
        identifier_type: 2,
        voided: 0
      )
      retained = create(
        :patient_identifier,
        patient:,
        identifier: "OLDER-#{SecureRandom.hex(5)}",
        identifier_type: 2,
        voided: 0
      )
      primary = create(
        :patient_identifier,
        patient:,
        identifier: "NEW-#{SecureRandom.hex(5)}",
        identifier_type: 3,
        voided: 0
      )
      record = { voidLegacyDdeIdentifiers: [requested.identifier] }.with_indifferent_access

      result = manager.void_legacy_dde_identifiers(patient.patient_id, record)

      expect(result).to be_success
      expect(PatientIdentifier.unscoped.find(requested.id).voided).to eq(1)
      expect(PatientIdentifier.unscoped.find(retained.id).voided).to eq(0)
      expect(PatientIdentifier.unscoped.find(primary.id).voided).to eq(0)
      expect(record[:voidLegacyDdeIdentifiers]).to eq([])
    end
  end

  describe '#assign_dde_identifier' do
    it 'replaces the active NPID and preserves the old value as a legacy alias' do
      patient = create(:patient)
      old_identifier = create(
        :patient_identifier,
        patient:,
        identifier: "OLD-#{SecureRandom.hex(5)}",
        identifier_type: 3,
        voided: 0
      )
      older_alias = create(
        :patient_identifier,
        patient:,
        identifier: "OLDER-#{SecureRandom.hex(5)}",
        identifier_type: 2,
        voided: 0
      )
      new_identifier = "NEW-#{SecureRandom.hex(5)}".upcase
      record = {
        program_id: 14,
        location_id: old_identifier.location_id,
        assignDdeIdentifier: { npid: new_identifier, operationID: SecureRandom.uuid }
      }.with_indifferent_access
      allow(DdeService).to receive(:dde_enabled?).and_return(false)

      result = manager.assign_dde_identifier(patient.id, record)

      expect(result).to be_success
      expect(PatientIdentifier.exists?(patient_id: patient.id, identifier_type: 3, identifier: new_identifier)).to be true
      expect(PatientIdentifier.exists?(patient_id: patient.id, identifier_type: 2, identifier: old_identifier.identifier)).to be true
      expect(PatientIdentifier.exists?(patient_id: patient.id, identifier_type: 2, identifier: older_alias.identifier)).to be true
      expect(PatientIdentifier.unscoped.find(old_identifier.id).voided).to eq(1)
      expect(record[:assignDdeIdentifier]).to be_nil
      expect(record[:identifierAssignmentStatus]).to eq('assigned')
    end
  end
end
