# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::VoidEncounters do
  subject(:saver) { described_class.new }

  describe '#void_encounters' do
    let(:operation_result) { double('OperationGuardResult', skipped?: false) }
    let(:original_location) { instance_double(Location, location_id: 1310) }
    let(:encounter_location) { instance_double(Location, location_id: 79) }
    let(:encounter) { instance_double(Encounter, voided?: false, location: encounter_location) }
    let(:encounter_scope) { double('EncounterScope') }
    let(:encounter_service) { instance_double(EncounterService, void: true) }

    around do |example|
      previous_location = Location.current
      Location.current = original_location
      example.run
    ensure
      Location.current = previous_location
    end

    before do
      allow(saver).to receive(:with_operation_guard).and_yield.and_return(operation_result)
      allow(saver).to receive(:encounter_service).and_return(encounter_service)
      allow(Encounter).to receive(:unscoped).and_return(encounter_scope)
      allow(encounter_scope).to receive(:where).with(patient_id: 33).and_return(encounter_scope)
      allow(encounter_scope).to receive(:find).with('4821').and_return(encounter)
      allow(encounter_scope).to receive(:find).with(4821).and_return(encounter)
    end

    it 'voids a saved encounter by encounter_id' do
      result = saver.void_encounters(
        { patientID: 33, void_encounters: [{ id: 4821, reason: 'Mistake/ Wrong Entry' }] }.with_indifferent_access
      )

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(encounter_service).to have_received(:void).with(encounter, 'Mistake/ Wrong Entry')
      expect(saver).to have_received(:with_operation_guard).with(hash_including(patient_id: 33))
      expect(Location.current).to eq(original_location)
    end

    it 'uses the encounter location while voiding cross-location dependent records' do
      locations_during_void = []
      allow(encounter_service).to receive(:void) { locations_during_void << Location.current }

      saver.void_encounters(
        { patientID: 33, void_encounters: [{ id: 4821, reason: 'Duplicate' }] }.with_indifferent_access
      )

      expect(locations_during_void).to eq([encounter_location])
      expect(Location.current).to eq(original_location)
    end

    it 'treats an already-voided encounter as successful so stale history can be rebuilt' do
      allow(encounter).to receive(:voided?).and_return(true)

      result = saver.void_encounters(
        { patientID: 33, void_encounters: [{ id: 4821, reason: 'Duplicate' }] }.with_indifferent_access
      )

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(encounter_service).not_to have_received(:void)
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
      result = saver.void_encounters({ patientID: 33, void_encounters: [{ reason: 'Duplicate' }] }.with_indifferent_access)

      expect(result).not_to be_success
      expect(result.errors.first).to include('Missing encounter_id or encounter_operation_id')
      expect(encounter_service).not_to have_received(:void)
    end

    it 'rejects a void request that cannot be tied to a patient' do
      result = saver.void_encounters(
        { void_encounters: [{ id: 4821, reason: 'Duplicate' }] }.with_indifferent_access
      )

      expect(result).not_to be_success
      expect(result.errors.first).to include('Missing patient_id')
      expect(encounter_service).not_to have_received(:void)
    end

    it 'collects an error when the reason is missing' do
      result = saver.void_encounters({ void_encounters: [{ id: 4821 }] }.with_indifferent_access)

      expect(result).not_to be_success
      expect(result.errors.first).to include('Missing reason')
      expect(encounter_service).not_to have_received(:void)
    end
  end
end
