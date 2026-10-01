# frozen_string_literal: true

require 'rails_helper'

require_relative '../../../app/services/drug_order_service'
require_relative '../../../app/services/nlims'

describe TbService::RegimenEngine do
  include DrugOrderService
  include ModelUtils

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
    TbService::RegimenEngine.new program:
  end
  let(:person) do
    Person.create(birthdate: date, gender: 'M')
  end
  let(:person_name) do
    PersonName.create(person_id: person.person_id, given_name: 'John',
                      family_name: 'Doe')
  end
  let(:patient) { Patient.create(patient_id: person.person_id) }
  let(:patient_identifier_type) { PatientIdentifierType.find_by_name('national id').id }
  let(:patient_identifier) do
    PatientIdentifier.create(patient_id: patient.patient_id, identifier: 'P170000000013',
                             identifier_type: patient_identifier_type,
                             date_created: Time.now, creator: 1, location_id: 700)
  end

  let(:encounter) do
    Encounter.create(patient:,
                     encounter_type: EncounterType.find_by_name('TB REGISTRATION').encounter_type_id,
                     program_id: program.program_id, encounter_datetime: date,
                     date_created: Time.now, creator: 1, provider_id: 1, location_id: 700)
  end

  describe 'TB Patient Regimen' do
    describe 'IPT Treatment Eligibility' do
      let(:minor) { Person.create(birthdate: 4.years.ago) }
      let(:adult) { Person.create(birthdate: 6.years.ago) }
      let(:minor_patient) { Patient.create(patient_id: minor.person_id) }
      it 'returns false when the person is not <= 5 years old' do
        expect(engine.is_eligible_for_ipt?(person: adult)).to eq(false)
      end
      context 'Minor has been diagnosed' do
        let(:diagnosis) do
          Encounter.create(type: encounter_type('Diagnosis'),
                           program:,
                           creator: 1,
                           provider_id: 1,
                           encounter_datetime: Time.now,
                           patient: minor_patient)
        end
        it 'returns true when minor does not have Tuberculosis' do
          Observation.create(encounter: diagnosis,
                             person: minor,
                             concept: concept('TB status'),
                             value_coded: concept('Negative').concept_id)

          expect(engine.is_eligible_for_ipt?(person: minor)).to eq(true)
        end
        it 'returns false other wise' do
          expect(engine.is_eligible_for_ipt?(person: minor)).to eq(false)
        end
      end
    end

    describe 'IPT dosage' do
      it 'prescribes a single morning dose of Isoniazid 100mg for patients up to 25 kilos' do
        drug = Drug.find_by!(name: 'INH or H (Isoniazid 100mg tablet)')

        expect(engine.ipt_drug(weight: 25)).to eq([{ am_dose: 1, noon_dose: 0, pm_dose: 0, drug:, id: drug.drug_id }])
      end

      it 'prescribes a single morning dose of Isoniazid 300mg for patients above 25 kilos' do
        drug = Drug.find_by!(name: 'INH or H (Isoniazid 300mg tablet)')

        expect(engine.ipt_drug(weight: 26)).to eq([{ am_dose: 1, noon_dose: 0, pm_dose: 0, drug:, id: drug.drug_id }])
      end
    end

    it 'return all TB drugs' do
      # The TUBERCULOSIS DRUGS concept set ships empty in the current metadata
      create(:concept_set, set: ConceptName.find_by!(name: 'TUBERCULOSIS DRUGS').concept,
                           concept: Drug.find_by!(name: 'Rifabutin (300mg)').concept)

      tb_drugs = Drug.tb_drugs
      drugs_names = tb_drugs.map(&:name)
      expect(drugs_names).to include('Rifabutin (300mg)')
    end
  end

  # Helpers methods

  def nlims
    return @nlims if @nlims

    @config = YAML.load_file "#{Rails.root}/config/application.yml"
    @nlims = ::Nlims.new config
    @nlims.auth config['lims_default_user'], config['lims_default_password']
    @nlims
  end

  def create_encounter(patient)
    create :encounter, type: encounter_type('TB REGISTRATION'),
                       patient:
  end

  def patient_weight(patient, encounter)
    create :observation, concept: concept('Weight'),
                         encounter:,
                         person: patient.person,
                         value_numeric: 70
  end

  def prescribe_drugs(patient, encounter)
    create :observation, concept: concept('Prescribe drugs'),
                         encounter:,
                         person: patient.person,
                         value_coded: concept('Yes').concept_id
  end

  def medication_orders(patient, encounter)
    create :observation, concept: concept('Medication orders'),
                         encounter:,
                         person: patient.person,
                         value_coded: concept('Rifampicin and isoniazid').concept_id
  end
end
