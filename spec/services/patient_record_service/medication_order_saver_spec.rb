# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordService::MedicationOrderSaver do
  subject(:saver) { described_class.new }

  let(:program) { double('Program') }
  let(:provider) { double('Person') }
  let(:user) { double('User', person: provider) }

  before do
    allow(Program).to receive(:find).with(14).and_return(program)
    allow(User).to receive(:find).with(7).and_return(user)
    allow(DispensationService).to receive(:create).and_return([])
  end

  describe '#save_dispensation_data' do
    it 'accepts dispensation arrays attached to newly-created medication orders' do
      result = saver.save_dispensation_data(
        123,
        { location_id: 700 },
        456,
        [{
          provider_id: 7,
          program_id: 14,
          patient_id: 123,
          drug_order_id: 111,
          date: '2026-04-27',
          quantity: '30'
        }]
      )

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(DispensationService).to have_received(:create).with(
        program,
        [{ drug_order_id: 456, date: '2026-04-27', quantity: '30' }],
        provider,
        700
      )
    end

    it 'uses saved dispensation order ids when no replacement order id is supplied' do
      record = {
        location_id: 700,
        MedicationOrder: {
          saved: [{
            dispensation: [{
              'provider_id' => 7,
              'program_id' => 14,
              'patient_id' => 123,
              'drug_order_id' => 111,
              'date' => '2026-04-27',
              'quantity' => '15'
            }]
          }]
        }
      }

      result = saver.save_dispensation_data(123, record)

      expect(result).to be_success
      expect(result.errors).to be_empty
      expect(DispensationService).to have_received(:create).with(
        program,
        [{ drug_order_id: 111, date: '2026-04-27', quantity: '15' }],
        provider,
        700
      )
    end
  end
end
