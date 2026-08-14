# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::VaccineManager do
  subject(:manager) { described_class.new }

  let(:pnc_program_id) { 35 }
  let(:immunization_program) { double('Program', program_id: 33, name: 'IMMUNIZATION PROGRAM') }
  let(:treatment_encounter_type) { double('EncounterType', id: 25) }
  let(:saved_order) { double('Order', order_id: 999) }

  let(:record) do
    {
      program_id: pnc_program_id,
      provider_id: 7,
      location_id: 700,
      encounter_datetime: '2026-08-10',
      vaccineAdministration: {
        orders: [{ drug_name: 'BCG', drug_inventory_id: 1, start_date: '2026-08-10' }],
        obs: [],
        voided: []
      }
    }
  end

  before do
    allow(EncounterType).to receive(:find_by_name).and_return(treatment_encounter_type)
    allow(Program).to receive(:find_by_name).with('IMMUNIZATION PROGRAM').and_return(immunization_program)
    allow(ConceptName).to receive(:find_by_name).with('Drugs dispensed')
                                                .and_return(double('ConceptName', concept_id: 2876))
    allow(AdministerVaccineService).to receive(:administer_vaccine)
    allow(Order).to receive(:where).and_return(double('relation', order: double('ordered', first: saved_order)))
    allow(manager).to receive(:create_encounter).and_return(4321)
    allow(manager).to receive(:ensure_drugs_dispensed_observation!)
    allow(PatientProgram).to receive(:unscoped).and_return(
      double('relation', where: double('scoped', exists?: true))
    )
    allow(ActiveRecord::Base).to receive(:transaction).and_yield
    allow(PatientRecordOperationGuard).to receive(:run!) do |**_kwargs, &block|
      PatientRecordOperationGuard::Result.new(state: :applied, value: block.call, receipt: nil)
    end
  end

  describe '#save_vaccines' do
    it 'administers vaccines under the immunization program even when the record is a PNC visit' do
      result = manager.save_vaccines(123, record)

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(AdministerVaccineService).to have_received(:administer_vaccine)
        .with(4321, anything, 33, anything, 7, 700)
    end

    it 'creates the treatment encounter under the immunization program' do
      manager.save_vaccines(123, record)

      expect(manager).to have_received(:create_encounter)
        .with(123, treatment_encounter_type.id, hash_including(program_id: 33))
    end

    it 'enrolls the patient in the immunization program when no active enrollment exists' do
      allow(PatientProgram).to receive(:unscoped).and_return(
        double('relation', where: double('scoped', exists?: false))
      )
      allow(PatientProgram).to receive(:create!)

      manager.save_vaccines(123, record)

      expect(PatientProgram).to have_received(:create!)
        .with(hash_including(program_id: 33, patient_id: 123, location_id: 700))
    end

    # The CouchDB listener hands records over as HashWithIndifferentAccess
    # (couchdb_changes_listener.rb), the REST endpoint as ActionController::Parameters.
    it 'overrides the program for offline records synced from CouchDB' do
      manager.save_vaccines(123, record.deep_stringify_keys.with_indifferent_access)

      expect(AdministerVaccineService).to have_received(:administer_vaccine)
        .with(4321, anything, 33, anything, 7, 700)
      expect(manager).to have_received(:create_encounter)
        .with(123, treatment_encounter_type.id, hash_including('program_id' => 33))
    end

    it 'overrides the program for records posted through the REST endpoint' do
      manager.save_vaccines(123, ActionController::Parameters.new(record.deep_stringify_keys))

      expect(AdministerVaccineService).to have_received(:administer_vaccine)
        .with(4321, anything, 33, anything, 7, 700)
    end
  end
end
