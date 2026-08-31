# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::RegimenEngine do
  let(:regimen_service) { ArtService::RegimenEngine.new program: program('HIV Program') }
  let(:patient) { create :patient }
  let(:vitals_encounter) { create :encounter_vitals, patient: }
  let(:dtg_ids) { Drug.where(concept_id: ConceptName.find_by_name('Dolutegravir').concept_id).collect(&:drug_id) }

  def concept(name)
    ConceptName.find_by_name(name)&.concept
  end

  def program(name)
    Program.find_by_name(name) || create(:program, name:)
  end

  def set_patient_weight(patient, weight)
    Observation.create(
      concept: concept('Weight'),
      encounter: vitals_encounter,
      person: patient.person,
      obs_datetime: Time.now,
      value_numeric: weight
    )
  end

  def create_patient(weight:, age:, gender:)
    new_patient = patient
    new_patient.person.gender = gender
    set_patient_weight(new_patient, weight)
    new_patient.person.birthdate = age.years.ago
    new_patient
  end

  describe :find_regimens do
    it 'raises ArgumentError if weight and age are not provided' do
      (expect { regimen_service.find_regimens }).to raise_error(ArgumentError)
    end

    it 'retrieves [0P, 2P, 9P, 11P] regimens only for weights < 6' do
      created_patient = create_patient(weight: 5.9, age: 3, gender: 'M')
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 5.9, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(
          '0P' => Array.new(1) { { drug_id: 1001, am: 1, pm: 1 } },
          '2P' => Array.new(1) { { drug_id: 1002, am: 1, pm: 1 } },
          '9P' => Array.new(1) { { drug_id: 1003, am: 1, pm: 1 } },
          '11P' => Array.new(1) { { drug_id: 1004, am: 1, pm: 1 } }
        )

      regimens = regimen_service.find_regimens_by_patient(patient: created_patient)

      expected_regimens = %w[0P 2P 9P 11P]
      expect(regimens.keys).to eq(expected_regimens)
    end

    it 'retrieves all regimens for women under 45 years' do
      patient = create_patient(age: 30, weight: 50, gender: 'F')
      expected_regimens = %w[0A 2A 4A 5A 6A 7A 8A 9A 10A 11A 12A 13A 14A 15A]
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 50.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(expected_regimens.index_with { Array.new(1) { { drug_id: 999, am: 1, pm: 1 } } })

      regimens = regimen_service.find_regimens_by_patient(patient: patient)

      expect(regimens.size).to be expected_regimens.size
      regimens.each_key { |k| expect(expected_regimens).to include k }
    end

    it 'retrieves all regimens for women above 45 years' do
      patient = create_patient(age: 45, weight: 50, gender: 'F')
      expected_regimens = %w[0A 2A 4A 5A 6A 7A 8A 9A 10A 11A 12A 13A 14A 15A]
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 50.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(expected_regimens.index_with { Array.new(1) { { drug_id: 999, am: 1, pm: 1 } } })

      regimens = regimen_service.find_regimens_by_patient(patient: patient)

      expect(regimens.size).to be expected_regimens.size
      regimens.each_key { |k| expect(expected_regimens).to include k }
    end

    it 'retrieves regimens [0A 2A 4P 9P 11P] for women under 30 kilos' do
      patient = create_patient(age: 30, weight: '29', gender: 'F')
      expected_regimens = Set.new(%w[0A 2A 4P 9P 11P])
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 29.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(expected_regimens.index_with { Array.new(1) { { drug_id: 999, am: 1, pm: 1 } } })

      regimens = regimen_service.find_regimens_by_patient(patient: patient)

      expect(Set.new(regimens.keys)).to eq(expected_regimens)
    end

    it 'retrieves all regimens for women above 35 kilos' do
      patient = create_patient(age: 30, weight: 35, gender: 'F')
      expected_regimens = %w[0A 2A 4A 5A 6A 7A 8A 9A 10A 11A 12A 13A 14A 15A]
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 35.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(expected_regimens.index_with { Array.new(1) { { drug_id: 999, am: 1, pm: 1 } } })

      regimens = regimen_service.find_regimens_by_patient(patient: patient)

      expect(regimens.size).to be expected_regimens.size
      regimens.each_key { |k| expect(expected_regimens).to include k }
    end

    it 'retrieves regimens [0A 2A 4P 9P 11P] for men under 30 kilos' do
      patient = create_patient(age: 30, weight: 29, gender: 'M')
      expected_regimens = Set.new(%w[0A 2A 4P 9P 11P])
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 29.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(expected_regimens.index_with { Array.new(1) { { drug_id: 999, am: 1, pm: 1 } } })

      regimens = regimen_service.find_regimens_by_patient(patient: patient)

      expect(Set.new(regimens.keys)).to eq(expected_regimens)
      regimens.each_key { |k| expect(expected_regimens).to include k }
    end

    it 'retrieves all regimens for men at least 35 kilos' do
      patient = create_patient(age: 30, weight: 35, gender: 'M')
      expected_regimens = %w[0A 2A 4A 5A 6A 7A 8A 9A 10A 11A 12A 13A 14A 15A]
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 35.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return(expected_regimens.index_with { Array.new(1) { { drug_id: 999, am: 1, pm: 1 } } })

      regimens = regimen_service.find_regimens_by_patient(patient: patient)

      expect(regimens.size).to be expected_regimens.size
      regimens.each_key { |k| expect(expected_regimens).to include k }
    end

    def put_patient_on_tb_treatment(patient)
      tb_status_concept_id = ConceptName.find_by_name('TB Status').concept_id
      rx_concept_id = concept('Rx').concept_id

      encounter = create(:encounter, program_id: regimen_service.program.program_id, patient:)

      create(:observation, person_id: patient.id,
                           concept_id: tb_status_concept_id,
                           encounter_id: encounter.encounter_id,
                           obs_datetime: Time.now,
                           value_coded: rx_concept_id)
    end

    it 'does not double dose DTG for 13A patients not on TB treatment' do
      patient = create_patient(age: 30, weight: 55, gender: 'M')
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 55.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return('13A' => [{ drug_id: 999, am: 1, pm: 1 }])

      regimen = regimen_service.find_regimens_by_patient(patient: patient)['13A']

      expect(regimen.size).to eq(1)
      expect(dtg_ids).not_to include(regimen[0][:drug_id])
    end

    it 'double doses DTG for 13A patients on TB treatment' do
      patient = create_patient(age: 30, weight: 55, gender: 'M')
      put_patient_on_tb_treatment(patient)

      allow(regimen_service).to receive(:use_tb_patient_dosage?).and_return(true)
      allow(regimen_service).to receive(:inject_dtg_into_regimen!) do |regimen, _patient_weight|
        regimen << { drug_id: dtg_ids.first, am: 0, pm: 1 }
      end

      regimens = { '13A' => [{ drug_id: 999, am: 1, pm: 1 }] }
      regimen_service.send(:repackage_regimens_for_tb_patients!, regimens, 55.0)

      regimen = regimens['13A']
      expect(regimen.size).to eq(2)

      regimen_dtgs = regimen.select { |drug| dtg_ids.include?(drug[:drug_id]) }

      expect(regimen_dtgs.size).to eq(1)
      expect(regimen_dtgs[0][:am]).to be_zero
      expect(regimen_dtgs[0][:pm]).to be > 0
    end

    it 'does not double dose DTG for 14A patients not on TB treatment' do
      patient = create_patient(age: 40, weight: 60, gender: 'F')
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 60.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return('14A' => [{ drug_id: dtg_ids.first, am: 1, pm: 0 }])

      regimen = regimen_service.find_regimens_by_patient(patient: patient)['14A']
      regimen_dtgs = regimen.select { |drug| dtg_ids.include?(drug[:drug_id]) }

      expect(regimen_dtgs.size).to eq(1)
      expect(regimen_dtgs[0][:am]).to be > 0
      expect(regimen_dtgs[0][:pm]).to be_zero
    end

    it 'double doses DTG for 14A patients on TB treatment' do
      patient = create_patient(age: 40, weight: 60, gender: 'F')
      put_patient_on_tb_treatment(patient)

      allow(regimen_service).to receive(:use_tb_patient_dosage?).and_return(true)

      regimens = { '14A' => [{ drug_id: dtg_ids.first, am: 1, pm: 0 }] }
      regimen_service.send(:repackage_regimens_for_tb_patients!, regimens, 60.0)

      regimen = regimens['14A']
      regimen_dtgs = regimen.select { |drug| dtg_ids.include?(drug[:drug_id]) }

      expect(regimen_dtgs.size).to eq(1)
      expect(regimen_dtgs[0][:am]).to eq(regimen_dtgs[0][:pm])
      expect(regimen_dtgs[0][:am]).to be > 0
      expect(regimen_dtgs[0][:pm]).to be > 0
    end

    it 'does not double dose DTG for 15A patients not on TB treatment' do
      patient = create_patient(age: 40, weight: 60, gender: 'F')
      allow(regimen_service).to receive(:find_regimens)
        .with(patient_weight: 60.0, use_tb_dosage: false, lpv_drug_type: 'tabs')
        .and_return('15A' => [{ drug_id: dtg_ids.first, am: 1, pm: 0 }])

      regimen = regimen_service.find_regimens_by_patient(patient: patient)['15A']
      regimen_dtgs = regimen.select { |drug| dtg_ids.include?(drug[:drug_id]) }

      expect(regimen_dtgs.size).to eq(1)
      expect(regimen_dtgs[0][:am]).to be > 0
      expect(regimen_dtgs[0][:pm]).to be_zero
    end

    it 'double doses DTG for 15A patients on TB treatment' do
      patient = create_patient(age: 40, weight: 60, gender: 'F')
      put_patient_on_tb_treatment(patient)

      allow(regimen_service).to receive(:use_tb_patient_dosage?).and_return(true)

      regimens = { '15A' => [{ drug_id: dtg_ids.first, am: 1, pm: 0 }] }
      regimen_service.send(:repackage_regimens_for_tb_patients!, regimens, 60.0)

      regimen = regimens['15A']
      regimen_dtgs = regimen.select { |drug| dtg_ids.include?(drug[:drug_id]) }

      expect(regimen_dtgs.size).to eq(1)
      expect(regimen_dtgs[0][:am]).to eq(regimen_dtgs[0][:pm])
      expect(regimen_dtgs[0][:am]).to be > 0
      expect(regimen_dtgs[0][:pm]).to be > 0
    end
  end
end
