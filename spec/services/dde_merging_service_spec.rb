# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DdeMergingService do
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
