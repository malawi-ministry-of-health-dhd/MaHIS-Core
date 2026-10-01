# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DdeMergingService do
  describe 'location scoping' do
    # A patient merged at one facility can have encounters, observations and
    # programmes recorded at another. Those rows must be merged too, so the
    # Locatable default scope is lifted for the duration of the merge.
    before { allow(Location).to receive(:current).and_return(instance_double(Location, id: 58)) }

    it 'filters encounters by the current location outside a merge' do
      expect(Encounter.where(patient_id: 1).to_sql).to include("`location_id` = '58'")
    end

    it 'lifts the location filter inside Locatable.without_location_scope and restores it after' do
      inside = Locatable.without_location_scope do
        [Encounter, Observation, PatientProgram].map { |model| model.where(person_or_patient_column(model) => 1).to_sql }
      end

      expect(inside).to all(satisfy { |sql| !sql.include?('location_id') })
      expect(Encounter.where(patient_id: 1).to_sql).to include("`location_id` = '58'")
    end

    it 'runs the whole local merge without the location filter' do
      service = described_class.new(nil, nil)
      primary = instance_double(Patient, id: 1, patient_id: 1)
      secondary = instance_double(Patient, id: 2, patient_id: 2, void: true)
      scope_disabled_during = {}

      allow(Patient).to receive(:find).with(1).and_return(primary)
      allow(Patient).to receive(:find).with(2).and_return(secondary)
      %i[merge_name merge_identifiers merge_attributes merge_address merge_programs].each do |step|
        allow(service).to receive(step)
      end
      allow(service).to receive(:female_male_merge?).and_return(false)
      allow(service).to receive(:merge_encounters) do
        scope_disabled_during[:encounters] = Encounter.where(patient_id: 2).to_sql.exclude?('location_id')
        {}
      end
      allow(service).to receive(:merge_observations)
      allow(service).to receive(:merge_orders) do
        scope_disabled_during[:orders] = Observation.where(person_id: 2).to_sql.exclude?('location_id')
      end
      allow(MergeAuditService).to receive(:new).and_return(double(create_merge_audit: true))

      service.send(:merge_local_patients, { 'patient_id' => 1 }, { 'patient_id' => 2 }, 'Local Patients')

      expect(scope_disabled_during).to eq(encounters: true, orders: true)
      expect(Encounter.where(patient_id: 2).to_sql).to include("`location_id` = '58'")
    end

    def person_or_patient_column(model)
      model == Observation ? :person_id : :patient_id
    end
  end

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

  describe '#merge_local_patients' do
    it 'raises when the primary and secondary patient are the same' do
      service = described_class.new(nil, nil)
      patient = instance_double(Patient, id: 500)
      allow(Patient).to receive(:find).with(500).and_return(patient)

      expect do
        service.merge_local_patients({ 'patient_id' => 500 }, { 'patient_id' => 500 }, 'Local Patients')
      end.to raise_error(InvalidParameterError, /Cannot merge a patient into itself/)
    end
  end

  describe '#merge_remote_and_local_patients' do
    it 'raises before contacting DDE when primary and secondary share the same local patient id' do
      service = described_class.new(nil, nil)

      expect(service).not_to receive(:reassign_remote_patient_npid)
      expect do
        service.send(:merge_remote_and_local_patients,
                     { 'patient_id' => 500 }, { 'patient_id' => 500, 'doc_id' => 'DOC1' }, 'Remote and Local Patient')
      end.to raise_error(InvalidParameterError, /Cannot merge a patient into itself/)
    end
  end

  describe '#merge_orders' do
    it 'fails the merge instead of silently dropping an order with no mapped encounter' do
      service = described_class.new(nil, nil)
      secondary_patient = create(:patient)
      primary_patient = create(:patient)
      order = create(:order, patient: secondary_patient)

      expect do
        service.send(:merge_orders, primary_patient, secondary_patient, {})
      end.to raise_error(/no merged encounter found for encounter ##{order.encounter_id}/)
    end
  end

  describe '#check_clinician?' do
    it 'treats a retired or deactivated creator as not a clinician instead of raising' do
      service = described_class.new(nil, nil)
      users = double('unscoped users')
      allow(User).to receive(:unscoped).and_return(users)
      allow(users).to receive(:find_by).with(user_id: 900).and_return(nil)

      expect(service.send(:check_clinician?, 900)).to be(false)
    end
  end

  describe '#persist_copied_order!' do
    it 'preserves a copied order when its provider was later retired or deactivated' do
      service = described_class.new(nil, nil)
      errors = instance_double(ActiveModel::Errors, attribute_names: [:provider])
      order = instance_double(Order, errors: errors)
      users = double('unscoped users')
      user_scope = double('user scope')
      allow(order).to receive(:save).and_return(false)
      allow(order).to receive(:save!).with(validate: false).and_return(true)
      allow(User).to receive(:unscoped).and_return(users)
      allow(users).to receive(:where).with(user_id: 700).and_return(user_scope)
      allow(user_scope).to receive(:exists?).and_return(true)

      expect(service.send(:persist_copied_order!, order, 700)).to eq(order)
      expect(order).to have_received(:save!).with(validate: false)
    end

    it 'does not bypass unrelated order validation failures' do
      service = described_class.new(nil, nil)
      errors = instance_double(
        ActiveModel::Errors,
        attribute_names: [:encounter],
        as_json: { encounter: ['must exist'] }
      )
      order = instance_double(Order, errors: errors)
      users = double('unscoped users')
      user_scope = double('user scope')
      allow(order).to receive(:save).and_return(false)
      allow(User).to receive(:unscoped).and_return(users)
      allow(users).to receive(:where).with(user_id: 700).and_return(user_scope)
      allow(user_scope).to receive(:exists?).and_return(true)

      expect do
        service.send(:persist_copied_order!, order, 700)
      end.to raise_error(/Could not merge patient orders/)
    end
  end
end
