# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BuildPatientRecordService do
  describe '.get_client_drug_orders' do
    it 'reads medication data without repairing missing MySQL drug_order rows' do
      expect(DrugOrderService).to receive(:fetch_all_patient_drug_orders)
        .with(123, repair_missing: false)
        .and_return([])

      expect(described_class.get_client_drug_orders(123)).to eq([])
    end
  end

  describe '.build_dispensations_data' do
    it 'reads pending dispensations without repairing missing MySQL drug_order rows' do
      patient = instance_double(Patient)
      patient_service = instance_double(PatientService)
      relation = instance_double(ActiveRecord::Relation, as_json: [])
      allow(described_class).to receive(:patient_service).and_return(patient_service)
      expect(patient_service).to receive(:find_program_drug_orders_awaiting_dispensation)
        .with(patient, Date.today, repair_missing: false)
        .and_return(relation)

      expect(described_class.build_dispensations_data(patient)).to eq(saved: [], unsaved: [])
    end
  end
end
