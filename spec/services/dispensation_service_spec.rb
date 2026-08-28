# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DispensationService do
  let(:patient) { create :patient }

  before(:each) do
    setup_cohort_test_data
  end

  describe :dispensations do
    it 'retrieves all dispensations for a given patient' do
      created = (1...10).collect do |i|
        create :dispensation, person: patient.person,
                              obs_datetime: Time.now - i.days
      end

      retrieved = DispensationService.dispensations patient.patient_id

      expect(Set.new(retrieved)).to eq(Set.new(created))
    end

    it 'retrieves dispensations for a given patient and date' do
      retro_date = 5.days.ago.to_date
      created = (1...10).collect do
        create :dispensation, person: patient.person, obs_datetime: retro_date
      end

      retrieved = DispensationService.dispensations patient.patient_id, retro_date

      expect(Set.new(retrieved)).to eq(Set.new(created))
    end
  end

  describe :dispense_drug do
    it 'updates order quantity' do
      program = Program.find_by_name('HIV PROGRAM') || create(:program, name: 'HIV PROGRAM')
      encounter = create(:encounter_treatment, patient:)
      drug = Drug.arv_drugs[0]
      order = create :order, encounter:, patient:,
                             concept: drug.concept, start_date: Date.today,
                             auto_expire_date: 10.days.after
      drug_order = create(:drug_order, order:, drug:)

      obs = DispensationService.dispense_drug(program, drug_order, 10)

      expect(obs.concept_id).to eq(ConceptName.find_by_name('AMOUNT DISPENSED').concept_id)
      expect(obs.order).to eq(order)
      expect(obs.order.drug_order.quantity).to eq(10)
    end
  end
end
