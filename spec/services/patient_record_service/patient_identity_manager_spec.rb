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
end
