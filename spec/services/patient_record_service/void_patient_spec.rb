# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::VoidPatient do
  subject(:saver) { described_class.new }

  describe '#void_patient' do
    let(:operation_result) { double('OperationGuardResult', skipped?: false) }
    let(:patient) { instance_double(Patient, voided?: false) }
    let(:patient_scope) { double('PatientScope') }
    let(:patient_service) { instance_double(PatientService, void_patient: true) }

    before do
      allow(saver).to receive(:with_operation_guard).and_yield.and_return(operation_result)
      allow(saver).to receive(:patient_service).and_return(patient_service)
      allow(Patient).to receive(:unscoped).and_return(patient_scope)
      allow(patient_scope).to receive(:find).with(33).and_return(patient)
    end

    it 'voids the patient with the given reason' do
      result = saver.void_patient(33, { void_patient: { reason: 'Duplicate' } }.with_indifferent_access)

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(patient_service).to have_received(:void_patient).with(patient, 'Duplicate', daemonize: false)
      expect(saver).to have_received(:with_operation_guard).with(hash_including(patient_id: 33, operation_type: 'patient.void'))
    end

    it 'is a no-op when no void_patient request is present' do
      result = saver.void_patient(33, {}.with_indifferent_access)

      expect(result).to be_success
      expect(patient_service).not_to have_received(:void_patient)
    end

    it 'fails when the reason is missing' do
      result = saver.void_patient(33, { void_patient: { reason: '' } }.with_indifferent_access)

      expect(result).to be_failed
      expect(result.errors).to include(match(/Missing reason/))
      expect(patient_service).not_to have_received(:void_patient)
    end

    it 'treats an already-voided patient as successful so retries are idempotent' do
      allow(patient).to receive(:voided?).and_return(true)

      result = saver.void_patient(33, { void_patient: { reason: 'Duplicate' } }.with_indifferent_access)

      expect(result).to be_success
      expect(patient_service).not_to have_received(:void_patient)
    end

    it 'fails gracefully when the patient cannot be found' do
      allow(patient_scope).to receive(:find).with(33).and_raise(ActiveRecord::RecordNotFound)

      result = saver.void_patient(33, { void_patient: { reason: 'Duplicate' } }.with_indifferent_access)

      expect(result).to be_failed
      expect(result.errors).to include(match(/Patient 33 not found/))
    end
  end
end
