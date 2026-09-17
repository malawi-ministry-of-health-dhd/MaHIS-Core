# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LabResultsQueueService do
  describe 'MRDT Lab filtering' do
    it 'adds an order-level MRDT test restriction to the pending queue SQL' do
      allow(described_class).to receive(:lab_order_type_ids).and_return([6])
      allow(described_class).to receive(:lab_result_concept_ids).and_return([])
      allow(described_class).to receive(:test_type_concept_ids).and_return([170])
      allow(described_class).to receive(:mrdt_lab_test_type_concept_ids).and_return([57_975])

      sql = described_class.send(
        :pending_lab_results_patients_sql,
        nil,
        show_hts_only: true,
        show_viral_load_only: true,
        mrdt_only: true
      )

      expect(sql).to include('FROM obs mrdt_test')
      expect(sql).to match(/mrdt_test\.concept_id IN \('?170'?\)/)
      expect(sql).to match(/mrdt_test\.value_coded IN \('?57975'?\)/)
    end

    it 'does not add the MRDT restriction for other lab users' do
      allow(described_class).to receive(:lab_order_type_ids).and_return([6])
      allow(described_class).to receive(:lab_result_concept_ids).and_return([])

      sql = described_class.send(
        :pending_lab_results_patients_sql,
        nil,
        show_hts_only: true,
        show_viral_load_only: true,
        mrdt_only: false
      )

      expect(sql).not_to include('mrdt_test')
    end
  end
end
