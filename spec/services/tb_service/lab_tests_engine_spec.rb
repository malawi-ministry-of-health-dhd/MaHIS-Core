# frozen_string_literal: true

require 'rails_helper'

describe TbService::LabTestsEngine do
  # The suite runs without transactional fixtures, roll back each example's records
  around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  let(:date) { Time.now }
  let(:program) { Program.find_by_name 'TB PROGRAM' }
  let(:engine) do
    TbService::LabTestsEngine.new program:
  end
  let(:nlims) { instance_double(Nlims) }
  let(:person) do
    Person.create(birthdate: date, gender: 'M')
  end
  let(:person_name) do
    PersonName.create(person_id: person.person_id, given_name: 'John',
                      family_name: 'Doe')
  end
  let(:patient) { Patient.create(patient_id: person.person_id) }
  let(:encounter) do
    Encounter.create(patient:,
                     encounter_type: EncounterType.find_by_name('TB_INITIAL').encounter_type_id,
                     program_id: program.program_id, encounter_datetime: date,
                     date_created: Time.now, creator: 1, provider_id: 1, location_id: Location.current.location_id)
  end

  # Test types, specimens and orders come from NLIMS, never hit the network in specs
  before do
    allow(Nlims).to receive(:instance).and_return(nlims)
    allow(nlims).to receive(:test_types).and_return(['TB Tests'])
    allow(nlims).to receive(:specimen_types).with('TB Tests').and_return(['Sputum'])
    allow(nlims).to receive(:order_tb_test).and_return('tracking_number' => '1234567890')
  end

  describe 'Lab Test Engine' do
    it 'returns all tests types from LIMS' do
      test_types = engine.types(search_string: 'TB Tests')
      expect(test_types).to include('TB Tests')
    end

    it 'returns specimen types for particular test type from LIMS' do
      test_types = engine.types(search_string: 'TB Tests')
      specimen_types = engine.panels(test_types.first)
      expect(specimen_types).to include('Sputum')
    end

    it 'returns created lab order' do
      person_name
      tests = [
        {
          'test_type' => 'TB Tests',
          'reason' => 'Patient a TB Suspect',
          'sample_type' => ['Sputum'],
          'sample_status' => 'Spec Sample Status',
          'target_lab' => 'Spec TB Lab 1',
          'recommended_examination' => 'Spec GeneXpert',
          'treatment_history' => 'Spec New',
          'sample_date' => Time.now,
          'sending_facility' => 'Spec TB Reception',
          'time_line' => 'NA'
        }
      ]

      orders = engine.create_order(encounter:, date:, tests:, requesting_clinician: person.person_id)

      expect(orders.size).to eq(1)
      expect(orders[0][:order]).to be_persisted
      expect(orders[0][:order].accession_number).to eq('1234567890')
      expect(orders[0][:lims_order]).to eq('tracking_number' => '1234567890')
    end
  end
end
