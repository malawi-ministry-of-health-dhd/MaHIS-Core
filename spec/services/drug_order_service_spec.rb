# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DrugOrderService do
  let(:patient) { create :patient }
  let(:provider_id) { default_provider.person_id }
  let(:service) { DrugOrderService }

  describe :create_drug_orders do
    let(:treatment_encounter) { create :encounter_treatment, patient:, provider_id: }
    let(:archetypes) do
      [
        {
          drug_inventory_id: Drug.arv_drugs[0].drug_id,
          start_date: Date.today,
          auto_expire_date: Date.today + 5.days,
          instructions: '1 2 3 4 5 6 7 8 9 10',
          dose: 2,
          prn: 'Whatever',
          units: 'tabs',
          frequency: 'AM, PM',
          equivalent_daily_dose: 6
        }
      ]
    end

    it 'creates a drug_order and an accompanying order for each archetype' do
      created = service.create_drug_orders encounter: treatment_encounter,
                                           drug_orders: archetypes.clone

      expect(created.size).to eq(1)
      expect(created[0].order).not_to be_nil
    end
  end

  describe :orderer_for do
    it 'credits the user who wrote the order, not the user syncing it' do
      prescriber = User.where.not(user_id: User.current.user_id).first
      skip 'needs a second user account in the test database' unless prescriber

      expect(service.send(:orderer_for, { provider_id: prescriber.user_id })).to eq(prescriber.user_id)
      expect(service.send(:orderer_for, { provider_id: prescriber.user_id })).not_to eq(User.current.user_id)
    end

    it 'accepts the provider under a string key, as an offline payload sends it' do
      expect(service.send(:orderer_for, { 'provider_id' => User.current.user_id })).to eq(User.current.user_id)
    end

    it 'falls back to the authenticated user when the item names no provider' do
      expect(service.send(:orderer_for, {})).to eq(User.current.user_id)
    end

    it 'falls back to the authenticated user when the provider is unknown' do
      expect(service.send(:orderer_for, { provider_id: 999_999_999 })).to eq(User.current.user_id)
    end
  end

  describe :fetch_all_patient_drug_orders do
    it 'includes the saved order instructions in the built drug order object' do
      instructions = 'HCTZ 25mg | AM:2 | N:1 | PM:1 | Dur:2 | Qty:8'
      connection = ActiveRecord::Base.connection

      allow(service).to receive(:repair_missing_drug_order_rows)
      allow(service).to receive(:dispensation_concept_ids).and_return([])
      allow(connection).to receive(:quote).with(123).and_return('123')
      expect(connection).to receive(:select_all) do |sql|
        expect(sql).to include('o.instructions AS instructions')
        [{ 'order_id' => 456, 'instructions' => instructions, 'dispensed' => 0 }]
      end

      expect(service.fetch_all_patient_drug_orders(123).first).to include(instructions:)
    end

    it 'includes the prescriber so a label printed while dispensing credits them' do
      connection = ActiveRecord::Base.connection

      allow(service).to receive(:repair_missing_drug_order_rows)
      allow(service).to receive(:dispensation_concept_ids).and_return([])
      allow(connection).to receive(:quote).with(123).and_return('123')
      expect(connection).to receive(:select_all) do |sql|
        expect(sql).to include('AS prescriber')
        [{ 'order_id' => 456, 'prescriber' => 'clinician', 'dispensed' => 0 }]
      end

      expect(service.fetch_all_patient_drug_orders(123).first).to include(prescriber: 'clinician')
    end

    it 'does not repair MySQL rows when repair_missing is false' do
      connection = ActiveRecord::Base.connection

      expect(service).not_to receive(:repair_missing_drug_order_rows)
      allow(service).to receive(:dispensation_concept_ids).and_return([])
      allow(connection).to receive(:quote).with(123).and_return('123')
      allow(connection).to receive(:select_all).and_return([])

      expect(service.fetch_all_patient_drug_orders(123, repair_missing: false)).to eq([])
    end
  end

  describe :dispensation_concept_ids do
    it 'uses the indexed name lookup and caches the result' do
      relation = instance_double(ActiveRecord::Relation)
      distinct_relation = instance_double(ActiveRecord::Relation)
      service.instance_variable_set(:@dispensation_concept_ids, nil)

      expect(ConceptName).to receive(:where)
        .once
        .with(voided: 0, name: 'Amount dispensed')
        .and_return(relation)
      expect(relation).to receive(:distinct).once.and_return(distinct_relation)
      expect(distinct_relation).to receive(:pluck).once.with(:concept_id).and_return([51_678])

      2.times { expect(service.send(:dispensation_concept_ids)).to eq([51_678]) }
    end
  end

  describe :patients_awaiting_dispensation do
    let(:location_id) { Location.current&.location_id || 700 }
    let(:drug) { Drug.first || create(:drug, name: 'Queue spec drug', form: create(:concept)) }

    def create_drug_order_for_queue(patient:, start_date: Date.current, encounter_datetime: Time.current, quantity: 0)
      encounter = create(
        :encounter_treatment,
        patient:,
        provider_id:,
        location_id:,
        encounter_datetime:
      )
      order = create(
        :order,
        encounter:,
        patient:,
        concept: drug.concept,
        start_date:,
        auto_expire_date: Date.current + 7.days
      )

      create(:drug_order, order:, drug:, quantity:)
    end

    def create_orphan_medication_order(patient:, start_date: Date.current, encounter_datetime: Time.current,
                                       instructions: "#{drug.name}: 1 tab(s) OD for 7 days")
      encounter = create(
        :encounter_treatment,
        patient:,
        provider_id:,
        location_id:,
        encounter_datetime:
      )

      create(
        :order,
        encounter:,
        patient:,
        concept: drug.concept,
        start_date:,
        auto_expire_date: Date.current + 7.days,
        instructions:
      )
    end

    def awaiting_patient_ids(date: Date.current)
      service
        .patients_awaiting_dispensation(date:, location_id:, per_page: 100)
        .fetch(:results)
        .map { |row| row[:patient_id].to_i }
    end

    it 'includes undispensed drug orders from the last 7 days' do
      drug_order = create_drug_order_for_queue(patient:)

      expect(awaiting_patient_ids).to include(drug_order.order.patient_id)
    end

    it 'keeps zero-amount dispensation attempts in the queue' do
      drug_order = create_drug_order_for_queue(patient:)
      create(
        :dispensation,
        person: patient.person,
        encounter: create(:encounter_dispensing, patient:, provider_id:, location_id:),
        order: drug_order.order,
        value_numeric: 0,
        obs_datetime: Time.current
      )

      expect(awaiting_patient_ids).to include(patient.patient_id)
    end

    it 'uses encounter date when an order start date is missing' do
      create_drug_order_for_queue(patient:, start_date: nil, encounter_datetime: Time.current)

      expect(awaiting_patient_ids).to include(patient.patient_id)
    end

    it 'excludes positively dispensed orders' do
      drug_order = create_drug_order_for_queue(patient:, quantity: 10)
      create(
        :dispensation,
        person: patient.person,
        encounter: create(:encounter_dispensing, patient:, provider_id:, location_id:),
        order: drug_order.order,
        value_numeric: 10,
        obs_datetime: Time.current
      )

      expect(awaiting_patient_ids).not_to include(drug_order.order.patient_id)
    end

    it 'repairs drug concept orders that were saved without drug_order rows' do
      exact_drug = create(:drug, concept: drug.concept, form: drug.form, name: 'Queue spec drug 500mg')
      order = create_orphan_medication_order(
        patient:,
        instructions: 'Queue spec drug 500mg: 2 tab(s) BD for 3 days'
      )

      expect do
        expect(awaiting_patient_ids).to include(patient.patient_id)
      end.to change { DrugOrder.exists?(order_id: order.order_id) }.from(false).to(true)

      repaired_order = DrugOrder.find(order.order_id)
      expect(repaired_order.drug_inventory_id).to eq(exact_drug.drug_id)
      expect(repaired_order.dose).to eq(2)
      expect(repaired_order.units).to eq('tab(s)')
      expect(repaired_order.frequency).to eq('BD')
      expect(repaired_order.equivalent_daily_dose).to eq(4)
      expect(repaired_order.quantity).to eq(0)
    end

    it 'repairs already dispensed orphan drug orders without returning them to the queue' do
      order = create_orphan_medication_order(patient:)
      create(
        :dispensation,
        person: patient.person,
        encounter: create(:encounter_dispensing, patient:, provider_id:, location_id:),
        order:,
        value_numeric: 5,
        obs_datetime: Time.current
      )
      create(
        :dispensation,
        person: patient.person,
        encounter: create(:encounter_dispensing, patient:, provider_id:, location_id:),
        order:,
        value_numeric: 7,
        obs_datetime: Time.current
      )

      expect(awaiting_patient_ids).not_to include(patient.patient_id)
      expect(DrugOrder.find(order.order_id).quantity).to eq(12)
    end
  end
end
