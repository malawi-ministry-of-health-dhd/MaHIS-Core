# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HardDeleteUnsyncablePatientsTask do
  describe 'candidate scope' do
    subject(:task) { described_class.new({}) }

    it 'includes unsyncable unenrolled patients or patients named test' do
      sql = task.send(:candidate_scope).to_sql

      expect(sql).to include('`patient`.`voided` = 0')
      expect(sql).to include('cleanup_identifier.identifier_type = 3')
      expect(sql).to include('cleanup_identifier.voided = 0')
      expect(sql).to include('cleanup_program.patient_id = patient.patient_id')
      expect(sql).to include('cleanup_name.person_id = patient.patient_id')
      expect(sql).to include("LOWER(TRIM(cleanup_name.given_name)) = 'test'")
      expect(sql).to include("LOWER(TRIM(cleanup_name.family_name)) = 'test'")
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
      allow(task).to receive(:rehome_visits_with_surviving_encounters)
      allow(task).to receive(:delete_merge_audits)
      allow(task).to receive(:delete_nonstandard_patient_references)
      allow(task).to receive(:delete_patient_program_children)

      expect(task).to receive(:prepare_related_ids).with(connection).ordered
      expect(task).to receive(:delete_nontransactional_patient_references)
        .with(connection).ordered
      expect(ActiveRecord::Base).to receive(:transaction)
        .with(requires_new: true).ordered.and_yield

      task.send(:delete_batch, connection)
    end
  end

  describe 'visit handling' do
    it 'selects only candidate-owned visits with no surviving encounter for deletion' do
      task = described_class.new({})
      connection = double('connection')
      captured = []
      allow(connection).to receive(:quote_table_name) { |name| "`#{name}`" }
      allow(task).to receive(:truncate_temp_table)
      allow(task).to receive(:insert_ids) do |_connection, table, sql|
        captured << [table, sql]
      end

      task.send(:prepare_related_ids, connection)

      visit_sql = captured.find { |table, _sql| table == described_class::TEMP_VISITS }.last
      expect(visit_sql).to include('batch.id = visit.patient_id')
      expect(visit_sql).to include('NOT EXISTS')
      expect(visit_sql).to include('target_encounter.id IS NULL')
      expect(captured.count { |table, _sql| table == described_class::TEMP_VISITS }).to eq(1)
    end

    it 'transfers candidate-owned visits to a patient with a surviving encounter' do
      task = described_class.new({})
      connection = double('connection')
      allow(connection).to receive(:quote_table_name) { |name| "`#{name}`" }
      allow(connection).to receive(:execute)

      task.send(:rehome_visits_with_surviving_encounters, connection)

      expect(connection).to have_received(:execute) do |sql|
        expect(sql).to include('UPDATE `visit` target_visit')
        expect(sql).to include('MIN(surviving_encounter.patient_id) AS surviving_patient_id')
        expect(sql).to include('SET target_visit.patient_id = surviving_visit.surviving_patient_id')
      end
    end
  end
end
