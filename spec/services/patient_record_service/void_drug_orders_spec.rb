# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::VoidDrugOrders do
  subject(:saver) { described_class.new }

  describe '#void_drug_orders' do
    let(:operation_result) { double('OperationGuardResult', skipped?: false) }
    let(:order) { instance_double(Order, voided?: false, void: true) }
    let(:drug_order) { instance_double(DrugOrder, order: order) }
    let(:drug_order_relation) { double('DrugOrder relation') }

    before do
      allow(saver).to receive(:with_operation_guard).and_yield.and_return(operation_result)
      allow(DrugOrder).to receive(:includes).with(:order).and_return(drug_order_relation)
      allow(drug_order_relation).to receive(:find).with(36956).and_return(drug_order)
      allow(DispensationService).to receive(:void_dispensations)
    end

    it 'voids string-keyed pending drug orders and marks the operation changed' do
      result = saver.void_drug_orders(
        33,
        {
          'voidedDrugOders' => {
            'unsaved' => [
              {
                'voidedDrugOders' => [
                  { 'drug_order_id' => 36956, 'reason' => 'Out of Stock' }
                ]
              }
            ]
          }
        }
      )

      expect(result).to be_success
      expect(result).to be_changed
      expect(DispensationService).to have_received(:void_dispensations).with(drug_order)
      expect(order).to have_received(:void).with('Out of Stock')
    end
  end
end
