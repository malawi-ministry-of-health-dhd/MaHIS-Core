# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordIdentityService do
  describe '.document_id' do
    it 'uses the durable person UUID rather than the mutable NPID' do
      patient = create(:patient)

      expect(described_class.document_id(patient:)).to eq(patient.person.uuid)
    end

    it 'uses an offline-generated UUID directly as the document ID' do
      record = { _id: '4f489184-3ff1-49e0-b642-7fdbba21c818', ID: 'NPID123' }

      expect(described_class.document_id(record:)).to eq('4f489184-3ff1-49e0-b642-7fdbba21c818')
    end
  end

  describe '.assignment_states' do
    it 'keeps the earliest owner and marks later owners of a shared NPID pending' do
      keeper = create(:patient)
      pending = create(:patient)
      shared = "SHARED-#{SecureRandom.hex(5)}"
      create(:patient_identifier, patient: keeper, identifier: shared, identifier_type: 3, voided: 0, date_created: 2.days.ago)
      create(:patient_identifier, patient: pending, identifier: shared, identifier_type: 3, voided: 0, date_created: 1.day.ago)

      states = described_class.assignment_states([keeper.id, pending.id])

      expect(states.dig(keeper.id, :pending)).to be false
      expect(states.dig(pending.id, :pending)).to be true
      expect(states.dig(pending.id, :duplicate_owner_count)).to eq(2)
    end
  end
end
