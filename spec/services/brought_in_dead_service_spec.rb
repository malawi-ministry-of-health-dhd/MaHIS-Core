# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BroughtInDeadService do
  let(:program) { create(:program) }
  let(:other_program) { create(:program) }

  # The suite runs without transactional cleanup, so rows outlive the example
  # that made them. A program of its own is not enough to isolate an example,
  # because encounters saved without a program count towards every program — so
  # each example gets a location of its own too, derived from its own program so
  # it stays unique without a shared counter.
  let(:location_id) { 1_000_000 + program.program_id }

  # The service matches the death-outcome encounter types by id, the same ones
  # the client sends, so the spec needs those exact rows.
  let(:outcome_encounter_type) { encounter_type(37, 'Patient outcome') }
  let(:legacy_encounter_type) { encounter_type(40, 'Legacy patient outcome') }
  let(:unrelated_encounter_type) { create(:encounter_type) }

  let(:death_concept) { concept_named('Death') }
  let(:date_of_death_concept) { concept_named('Date of death') }

  def encounter_type(id, name)
    EncounterType.find_by(encounter_type_id: id) || create(:encounter_type, encounter_type_id: id, name:)
  end

  def concept_named(name)
    existing = ConceptName.find_by(name:)
    return existing.concept if existing

    create(:concept).tap { |concept| create(:concept_name, concept:, name:) }
  end

  # Records one brought-in-dead encounter: a death observation with the date of
  # death hanging off it, which is the shape the client writes.
  def record_death(patient: create(:patient), program: self.program, location: location_id,
                   type: outcome_encounter_type, date_of_death: '06 Jan, 2026')
    encounter = create(:encounter, patient:, program:, location_id: location, type:)
    death = create(:observation, encounter:, person: patient.person, concept: death_concept)

    if date_of_death
      create(:observation, encounter:, person: patient.person, concept: date_of_death_concept,
                           obs_group_id: death.obs_id, value_text: date_of_death)
    end

    [encounter, death]
  end

  def count(**args)
    described_class.count(program_id: program.program_id, location_id:, **args)
  end

  def list(**args)
    described_class.list(program_id: program.program_id, location_id:, **args)
  end

  describe '.count' do
    it 'counts one record per brought-in-dead encounter' do
      2.times { record_death }

      expect(count).to eq(2)
    end

    it 'returns zero when nothing has been recorded' do
      expect(count).to eq(0)
    end

    it 'counts a patient once when the same death is recorded twice on the same date' do
      patient = create(:patient)
      record_death(patient:, date_of_death: '06 Jan, 2026')
      record_death(patient:, date_of_death: '06 Jan, 2026')

      expect(count).to eq(1)
    end

    it 'counts a patient once per date when deaths are recorded on different dates' do
      patient = create(:patient)
      record_death(patient:, date_of_death: '06 Jan, 2026')
      record_death(patient:, date_of_death: '08 Jan, 2026')

      expect(count).to eq(2)
    end

    it 'ignores a duplicate death observation inside one encounter' do
      patient = create(:patient)
      encounter, = record_death(patient:)
      create(:observation, encounter:, person: patient.person, concept: death_concept)

      expect(count).to eq(1)
    end

    it 'counts the legacy death-outcome encounter type' do
      record_death(type: legacy_encounter_type)

      expect(count).to eq(1)
    end

    it 'excludes encounters that are not death outcomes' do
      record_death(type: unrelated_encounter_type)

      expect(count).to eq(0)
    end

    it 'excludes encounters recorded for another program' do
      record_death(program: other_program)

      expect(count).to eq(0)
    end

    it 'includes encounters recorded without a program' do
      encounter, = record_death
      encounter.update_column(:program_id, nil)

      expect(count).to eq(1)
    end

    it 'excludes encounters recorded at another location' do
      record_death(location: location_id + 1)

      expect(count).to eq(0)
    end

    it 'counts every location when no location is given and the user has none' do
      allow(User).to receive(:current).and_return(nil)
      # Dropping the location filter also exposes the program-less rows other
      # examples left behind, so measure the change rather than the total.
      baseline = described_class.count(program_id: program.program_id)
      record_death(location: location_id + 1)

      expect(described_class.count(program_id: program.program_id)).to eq(baseline + 1)
    end

    it 'excludes voided death observations' do
      _encounter, death = record_death
      death.update_column(:voided, 1)

      expect(count).to eq(0)
    end

    it 'excludes voided encounters' do
      encounter, = record_death
      encounter.update_column(:voided, 1)

      expect(count).to eq(0)
    end

    it 'counts a record that has no date of death recorded' do
      record_death(date_of_death: nil)

      expect(count).to eq(1)
    end
  end
  describe '.list' do
    let(:place_of_death_concept) { concept_named('Place of death') }
    let(:guardian_concept) { concept_named('Guardian; name and first names') }
    let(:confirmed_by_concept) { concept_named('Responsible person present') }
    let(:date_of_confirmation_concept) { concept_named('Date of confinement') }

    # The client writes the rest of the row as observations hanging off the
    # death observation, the same way #record_death attaches the date of death.
    def record_detail(encounter, death, concept, value)
      create(:observation, encounter:, person: encounter.patient.person, concept:,
                           obs_group_id: death.obs_id, value_text: value)
    end

    # Identifier types are reference data the schema requires to exist, and the
    # service reads them by id the way the client does.
    def identifier_type(id, name)
      PatientIdentifierType.find_by(patient_identifier_type_id: id) ||
        PatientIdentifierType.create!(patient_identifier_type_id: id, name:, description: name,
                                      creator: 1, date_created: Time.now)
    end

    it 'returns one row per brought-in-dead encounter' do
      2.times { record_death }

      expect(list.length).to eq(2)
    end

    it 'returns nothing when nothing has been recorded' do
      expect(list).to eq([])
    end

    it 'reads the row off the observations hanging from the death' do
      encounter, death = record_death(date_of_death: '06 Jan, 2026')
      record_detail(encounter, death, place_of_death_concept, 'Home')
      record_detail(encounter, death, guardian_concept, 'James')
      record_detail(encounter, death, confirmed_by_concept, 'Danielle')
      record_detail(encounter, death, date_of_confirmation_concept, '07 Jan, 2026')

      expect(list.first).to include(
        place_of_death: 'Home',
        date_of_death: '06 Jan, 2026',
        brought_by: 'James',
        confirmed_by: 'Danielle',
        date_of_confirmation: '07 Jan, 2026'
      )
    end

    # An unrecorded person confirming the death falls back to whoever recorded
    # the encounter, and an unrecorded confirmation date to when they did.
    it 'falls back to the encounter when the confirmation was not recorded' do
      provider = create(:person)
      create(:person_name, person: provider, given_name: 'Ruth', family_name: 'Chongoza')
      encounter, = record_death
      encounter.update_column(:provider_id, provider.person_id)

      row = list.first
      expect(row[:confirmed_by]).to eq('Ruth Chongoza')
      expect(row[:date_of_confirmation].to_time).to be_within(1.second).of(encounter.encounter_datetime)
    end

    it 'carries the identifiers the client opens the record with' do
      patient = create(:patient)
      create(:patient_identifier, patient:, identifier: 'P103200000477',
                                  type: identifier_type(BroughtInDeadService::RECORD_IDENTIFIER_TYPE, 'National id'))
      create(:patient_identifier, patient:, identifier: 'MW-123',
                                  type: identifier_type(BroughtInDeadService::MALAWI_NATIONAL_ID_TYPE, 'Malawi national id'))
      record_death(patient:)

      row = list.first
      expect(row[:national_id]).to eq('MW-123')
      expect(row[:patient_lookup_ids]).to eq(['P103200000477', patient.patient_id.to_s])
    end

    it 'returns one row when the same death is recorded twice inside one encounter' do
      patient = create(:patient)
      encounter, = record_death(patient:)
      create(:observation, encounter:, person: patient.person, concept: death_concept)

      expect(list.length).to eq(1)
    end

    it 'scopes rows the same way the count does' do
      record_death(program: other_program)
      record_death(location: location_id + 1)
      record_death(type: unrelated_encounter_type)
      record_death

      expect(list.length).to eq(count)
    end

    it 'returns the newest record first' do
      older, = record_death
      newer, = record_death
      older.update_column(:encounter_datetime, 2.days.ago)
      newer.update_column(:encounter_datetime, 1.day.ago)

      expect(list.map { |row| row[:patient_id] }).to eq([newer.patient_id, older.patient_id])
    end
  end
end
