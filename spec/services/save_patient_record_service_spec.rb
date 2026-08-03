# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SavePatientRecordService do
  describe '#rebuild_all_observations' do
    it 'removes a stale encounter type when MySQL has no non-voided observations for it' do
      patient_data = {
        observations: [
          { encounter_type: 37, status: 'saved', obs: [{ encounter_id: 4821 }] },
          { encounter_type: 99, status: 'saved', obs: [{ encounter_id: 9001 }] }
        ]
      }.with_indifferent_access

      allow(BuildPatientRecordService).to receive(:build_all_observations)
        .with(33, [37])
        .and_return([])

      described_class.new.send(:rebuild_all_observations, 33, patient_data, [37])

      expect(patient_data[:observations].map { |group| group['encounter_type'] }).to eq([99])
    end

    it 'replaces the entire refreshed encounter type with authoritative MySQL data' do
      patient_data = {
        observations: [
          { encounter_type: '37', status: 'saved', obs: [{ encounter_id: 4821 }] },
          { encounter_type: 99, status: 'saved', obs: [{ encounter_id: 9001 }] }
        ]
      }.with_indifferent_access
      rebuilt_group = {
        encounter_type: 37,
        status: 'saved',
        obs: [{ encounter_id: 4822 }]
      }

      allow(BuildPatientRecordService).to receive(:build_all_observations)
        .with(33, [37])
        .and_return([rebuilt_group])

      described_class.new.send(:rebuild_all_observations, 33, patient_data, [37])

      refreshed_group = patient_data[:observations].find { |group| group['encounter_type'].to_s == '37' }
      expect(refreshed_group['obs'].map { |obs| obs['encounter_id'] }).to eq([4822])
      expect(patient_data[:observations].count { |group| group['encounter_type'].to_s == '37' }).to eq(1)
    end
  end
end
