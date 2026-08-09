# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DdeMergingService do
  describe '#create_local_patient_identifier' do
    it 'uses the unscoped creator location when linking a DDE identifier' do
      service = described_class.new(nil, nil)
      patient = instance_double(Patient, id: 559_604, creator: 2498)
      creator = instance_double(User, location_id: 32)
      users = double('unscoped users')
      identifier_type = instance_double(PatientIdentifierType)
      identifier = instance_double(PatientIdentifier)

      allow(User).to receive(:unscoped).and_return(users)
      allow(users).to receive(:find_by).with(user_id: 2498).and_return(creator)
      allow(service).to receive(:patient_identifier_type).with('National id').and_return(identifier_type)
      allow(PatientIdentifier).to receive(:create!).and_return(identifier)
      allow(patient).to receive(:reload).and_return(patient)

      expect(service.send(:create_local_patient_identifier, patient, 'KHYMWE', 'National id')).to eq(identifier)
      expect(PatientIdentifier).to have_received(:create!).with(
        identifier: 'KHYMWE', type: identifier_type, location_id: 32, patient:
      )
    end
  end

  describe '#matching_observation' do
    it 'safely compares observation text containing an apostrophe' do
      observation = Observation.new(
        concept_id: 1,
        obs_datetime: Time.zone.parse('2025-01-01 10:00:00'),
        value_text: "don't know"
      )

      expect do
        described_class.new(nil, nil).send(:matching_observation, -999_999, observation)
      end.not_to raise_error
    end
  end

  describe '#persist_copied_encounter!' do
    it 'preserves a historical encounter when its provider exists but is voided' do
      service = described_class.new(nil, nil)
      errors = instance_double(ActiveModel::Errors, attribute_names: [:provider])
      encounter = instance_double(Encounter, errors: errors)
      people = double('unscoped people')
      provider_scope = double('provider scope')
      allow(encounter).to receive(:save).and_return(false)
      allow(encounter).to receive(:save!).with(validate: false).and_return(true)
      allow(Person).to receive(:unscoped).and_return(people)
      allow(people).to receive(:where).with(person_id: 1988).and_return(provider_scope)
      allow(provider_scope).to receive(:exists?).and_return(true)

      expect(service.send(:persist_copied_encounter!, encounter, 1988)).to eq(encounter)
      expect(encounter).to have_received(:save!).with(validate: false)
    end

    it 'does not bypass unrelated encounter validation failures' do
      service = described_class.new(nil, nil)
      errors = instance_double(
        ActiveModel::Errors,
        attribute_names: [:encounter_datetime],
        as_json: { encounter_datetime: ['is invalid'] }
      )
      encounter = instance_double(Encounter, errors: errors)
      people = double('unscoped people')
      provider_scope = double('provider scope')
      allow(encounter).to receive(:save).and_return(false)
      allow(Person).to receive(:unscoped).and_return(people)
      allow(people).to receive(:where).with(person_id: 1988).and_return(provider_scope)
      allow(provider_scope).to receive(:exists?).and_return(true)

      expect do
        service.send(:persist_copied_encounter!, encounter, 1988)
      end.to raise_error(/Could not merge patient encounters/)
    end
  end
end
