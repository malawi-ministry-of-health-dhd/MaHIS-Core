# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BedManagementService do
  subject(:service) { described_class.new }

  let(:current_user) { instance_double(User, user_id: 9) }
  let(:bed) { instance_double(Bed, bed_id: 1, retired?: false, bed_status: Bed::ACTIVE_STATUS) }
  let(:patient) { instance_double(Patient, patient_id: 123) }
  let(:bed_relation) { double('Bed::Relation') }
  let(:patient_relation) { double('Patient::Relation') }

  describe '#allocate_bed' do
    let(:params) { { bed_id: 1, patient_id: 123 } }

    before do
      allow(BedAllocation).to receive(:transaction).and_yield
      allow(Bed).to receive(:unscoped).and_return(bed_relation)
      allow(bed_relation).to receive(:lock).and_return(bed_relation)
      allow(bed_relation).to receive(:find_by).with(bed_id: 1).and_return(bed)
      allow(Patient).to receive(:lock).and_return(patient_relation)
      allow(patient_relation).to receive(:find_by).with(patient_id: 123).and_return(patient)
      allow(BedAllocation).to receive(:create!)
      allow(BedAllocation).to receive_message_chain(:unscoped, :active, :for_bed, :exists?).and_return(false)
      allow(BedAllocation).to receive_message_chain(:unscoped, :active, :for_patient, :exists?).and_return(false)
    end

    it 'locks the bed and patient before creating an allocation' do
      service.allocate_bed(params, current_user)

      expect(BedAllocation).to have_received(:transaction)
      expect(bed_relation).to have_received(:lock)
      expect(Patient).to have_received(:lock)
      expect(BedAllocation).to have_received(:create!)
    end

    it 'raises a conflict error when the locked bed already has an active allocation' do
      allow(BedAllocation).to receive_message_chain(:unscoped, :active, :for_bed, :exists?).and_return(true)

      expect { service.allocate_bed(params, current_user) }
        .to raise_error(InvalidParameterError, 'bed_already_occupied')
    end
  end
end
