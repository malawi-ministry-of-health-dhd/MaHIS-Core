# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::Reports::Pepfar::TxTb do
  describe '#find_report' do
    it 'counts a TX_CURR patient with no CXR or MWRD method under symptom screening alone' do
      report = described_class.allocate
      report.instance_variable_set(:@report_type, 'pepfar')
      report.instance_variable_set(:@tx_curr, [])

      allow(report).to receive(:drop_temporary_tables)
      allow(report).to receive(:process_tb_screening)
      allow(report).to receive(:process_tb_confirmed_and_on_treatment)
      allow(report).to receive(:find_patients_alive_and_on_art).and_return([
        { 'patient_id' => 915, 'gender' => 'M', 'age_group' => '25-29 years' }
      ])
      allow(report).to receive(:find_tb_screened_data).and_return([
        {
          'patient_id' => 915,
          'gender' => 'M',
          'age_group' => '25-29 years',
          'enrollment_date' => Date.new(2020, 1, 1),
          'tb_status' => 'TB Suspected',
          'screening_methods' => nil
        }
      ])
      allow(report).to receive(:find_tb_confirmed_data).and_return([])

      result = report.find_report

      expect(report.instance_variable_get(:@tx_curr)).to contain_exactly(915)
      expect(result.dig('25-29 years', :M, :symptom_screen_alone)).to contain_exactly(915)
    end
  end
end