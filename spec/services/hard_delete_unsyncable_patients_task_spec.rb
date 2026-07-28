# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HardDeleteUnsyncablePatientsTask do
  describe 'candidate scope' do
    subject(:task) { described_class.new({}) }

    it 'requires no valid type-3 identifier and no program row' do
      sql = task.send(:candidate_scope).to_sql

      expect(sql).to include('`patient`.`voided` = 0')
      expect(sql).to include('cleanup_identifier.identifier_type = 3')
      expect(sql).to include('cleanup_identifier.voided = 0')
      expect(sql).to include('cleanup_program.patient_id = patient.patient_id')
    end
  end

  describe 'destructive confirmation' do
    it 'allows apply mode without an expected count' do
      expect do
        described_class.new(
          'APPLY' => '1',
          'CONFIRM' => described_class::CONFIRMATION
        )
      end.not_to raise_error
    end

    it 'requires the exact hard-delete phrase' do
      expect do
        described_class.new(
          'APPLY' => '1',
          'CONFIRM' => 'DELETE'
        )
      end.to raise_error(/CONFIRM=HARD_DELETE_COMPLETE_PATIENT_RECORDS/)
    end
  end

  describe '#prepare_batch' do
    it 'uses the Rails 8.1 adapter-supported select_rows API' do
      task = described_class.new({})
      connection = double('connection')

      allow(connection).to receive(:quote_table_name) { |name| "`#{name}`" }
      allow(connection).to receive(:execute)
      allow(connection).to receive(:select_rows).and_return([[500, 170_000]])

      result = task.send(:prepare_batch, connection, 0)

      expect(result).to eq([500, 170_000])
      expect(connection).to have_received(:select_rows)
        .with('SELECT COUNT(*), MAX(id) FROM `tmp_hard_delete_patient_batch`')
    end
  end

  describe '#delete_batch' do
    it 'deletes non-transactional references before opening the InnoDB transaction' do
      task = described_class.new({})
      connection = double('connection')

      allow(task).to receive(:break_circular_clinical_references)
      allow(task).to receive(:delete_nested_clinical_children)
      allow(task).to receive(:delete_nonstandard_foreign_keys)
      allow(task).to receive(:delete_tables_with_column)
      allow(task).to receive(:delete_join)
      allow(task).to receive(:delete_merge_audits)
      allow(task).to receive(:delete_nonstandard_patient_references)

      expect(task).to receive(:prepare_related_ids).with(connection).ordered
      expect(task).to receive(:delete_nontransactional_patient_references)
        .with(connection).ordered
      expect(ActiveRecord::Base).to receive(:transaction)
        .with(requires_new: true).ordered.and_yield

      task.send(:delete_batch, connection)
    end
  end
end
