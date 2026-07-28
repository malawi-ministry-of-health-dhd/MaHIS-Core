# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::VoidEncounters do
  subject(:saver) { described_class.new }

  describe '#void_encounters' do
    let(:operation_result) { double('OperationGuardResult', skipped?: false) }
    let(:encounter) { instance_double(Encounter) }
    let(:encounter_service) { instance_double(EncounterService, void: true) }

    before do
      allow(saver).to receive(:with_operation_guard).and_yield.and_return(operation_result)
      allow(saver).to receive(:encounter_service).and_return(encounter_service)
      allow(Encounter).to receive(:find).with('4821').and_return(encounter)
      allow(Encounter).to receive(:find).with(4821).and_return(encounter)
    end

    it 'voids a saved encounter by encounter_id' do
      result = saver.void_encounters(
        { void_encounters: [{ id: 4821, reason: 'Mistake/ Wrong Entry' }] }.with_indifferent_access
      )

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(encounter_service).to have_received(:void).with(encounter, 'Mistake/ Wrong Entry')
    end

    it 'resolves an unsaved encounter through its observation operation receipt' do
      PatientRecordOperationReceipt.create!(
        patient_id: 33,
        operation_type: 'observation_encounter.create',
        operation_id: 'user_observation_encounter_abc',
        status: 'completed',
        target_type: 'Encounter',
        target_id: '4821',
        completed_at: Time.current
      )

      record = {
        void_encounters: [
          {
            encounter_operation_id: 'user_observation_encounter_abc',
            patient_id: 33,
            reason: 'Duplicate'
          }
        ]
      }.with_indifferent_access

      result = saver.void_encounters(record)

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(encounter_service).to have_received(:void).with(encounter, 'Duplicate')
      # The resolved id is written back so the record rebuild refreshes this encounter type.
      expect(record.dig(:void_encounters, 0, :id)).to eq('4821')
    end

    it 'is a no-op when the unsaved encounter never reached MySQL' do
      result = saver.void_encounters(
        {
          void_encounters: [
            { encounter_operation_id: 'user_observation_encounter_never_saved', patient_id: 33, reason: 'Duplicate' }
          ]
        }.with_indifferent_access
      )

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(encounter_service).not_to have_received(:void)
    end

    it 'ignores receipts that failed instead of completing' do
      PatientRecordOperationReceipt.create!(
        patient_id: 33,
        operation_type: 'observation_encounter.create',
        operation_id: 'user_observation_encounter_failed',
        status: 'failed',
        target_type: 'Encounter',
        target_id: '4821'
      )

      result = saver.void_encounters(
        {
          void_encounters: [
            { encounter_operation_id: 'user_observation_encounter_failed', patient_id: 33, reason: 'Duplicate' }
          ]
        }.with_indifferent_access
      )

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(encounter_service).not_to have_received(:void)
    end

    it 'collects an error when neither an encounter_id nor an operation_id is supplied' do
      result = saver.void_encounters({ void_encounters: [{ reason: 'Duplicate' }] }.with_indifferent_access)

      expect(result).to be_success
      expect(result.errors.first).to include('Missing encounter_id or encounter_operation_id')
      expect(encounter_service).not_to have_received(:void)
    end

    it 'collects an error when the reason is missing' do
      result = saver.void_encounters({ void_encounters: [{ id: 4821 }] }.with_indifferent_access)

      expect(result).to be_success
      expect(result.errors.first).to include('Missing reason')
      expect(encounter_service).not_to have_received(:void)
    end
  end
end
