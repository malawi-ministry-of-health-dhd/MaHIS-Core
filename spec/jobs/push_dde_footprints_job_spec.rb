# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PushDdeFootprintsJob, type: :job do
  let(:location)    { Location.find_by!(location_id: 700) }
  let(:patient)     { create(:patient) }
  let(:program)     { create(:program) }
  let(:date)        { '2026-07-21' }
  let(:creator_id)  { 1 }
  let(:location_id) { 700 }

  describe '#perform' do
    let(:dde_service_double) { instance_double(DdeService) }

    before do
      allow(DdeService).to receive(:new).and_return(dde_service_double)
      allow(dde_service_double).to receive(:create_patient_footprint)
    end

    it 'sets Location.current to the given location_id before calling DDE' do
      captured_location = nil
      allow(dde_service_double).to receive(:create_patient_footprint) do
        captured_location = Location.current
      end

      described_class.perform_now(
        program_id: program.id,
        patient_id: patient.id,
        location_id: location_id,
        date: date,
        creator_id: creator_id
      )

      expect(captured_location&.location_id).to eq(location_id)
    end

    it 'calls create_patient_footprint with the correct patient and date' do
      described_class.perform_now(
        program_id: program.id,
        patient_id: patient.id,
        location_id: location_id,
        date: date,
        creator_id: creator_id
      )

      expect(dde_service_double).to have_received(:create_patient_footprint)
        .with(instance_of(Patient), Date.parse(date), creator_id)
    end

    it 'sets Location.current before DdeService is instantiated' do
      location_at_init = nil
      allow(DdeService).to receive(:new) do |**_args|
        location_at_init = Location.current
        dde_service_double
      end

      described_class.perform_now(
        program_id: program.id,
        patient_id: patient.id,
        location_id: location_id,
        date: date,
        creator_id: creator_id
      )

      expect(location_at_init&.location_id).to eq(location_id)
    end
  end
end
