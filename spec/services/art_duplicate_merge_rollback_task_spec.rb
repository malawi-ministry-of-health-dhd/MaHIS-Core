# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtDuplicateMergeRollbackTask do
  describe 'apply safeguards' do
    it 'requires the exact confirmation phrase' do
      expect do
        described_class.new({
          'APPLY' => '1', 'CONFIRM' => 'RESTORE', 'USER_ID' => '1',
          'APPROVAL_FILE' => __FILE__
        })
      end.to raise_error(/CONFIRM=RESTORE_REVIEWED_ART_DUPLICATE_MERGES_WITHOUT_DELETING/)
    end

    it 'requires a review file and operator user' do
      expect do
        described_class.new({ 'APPLY' => '1', 'CONFIRM' => described_class::CONFIRMATION })
      end.to raise_error(/USER_ID/)

      expect do
        described_class.new({
          'APPLY' => '1', 'CONFIRM' => described_class::CONFIRMATION, 'USER_ID' => '1'
        })
      end.to raise_error(/APPROVAL_FILE/)
    end

    it 'allows apply without a review file when every discovered group is explicitly approved' do
      expect do
        described_class.new({
          'APPLY' => '1', 'APPROVE_ALL' => '1',
          'CONFIRM' => described_class::CONFIRMATION, 'USER_ID' => '1'
        })
      end.not_to raise_error
    end

    it 'requires different source and target databases' do
      expect do
        described_class.new({ 'SOURCE_DB' => 'same', 'TARGET_DB' => 'same' })
      end.to raise_error(/must differ/)
    end
  end

  describe 'review group validation' do
    subject(:task) { described_class.new({}) }

    let(:values) do
      {
        'approved' => 'yes',
        'primary_source_id' => '10',
        'primary_uuid' => 'primary-uuid',
        'secondary_source_id' => '20',
        'secondary_uuid' => 'secondary-uuid',
        'cleanup_at' => '2026-08-09T10:00:00+02:00',
        'new_encounter_count' => '1',
        'new_encounter_uuids' => 'encounter-uuid',
        'recommended_new_encounter_owner_uuid' => 'secondary-uuid',
        'new_encounter_owner_uuid' => 'secondary-uuid'
      }
    end

    it 'requires one reviewed owner for new encounters' do
      values['new_encounter_owner_uuid'] = ''
      values['identity_hash'] = task.send(:review_hash, values)

      expect do
        task.send(:validate_complete_group!, values['primary_uuid'], [values], [values])
      end.to raise_error(/new_encounter_owner_uuid/)
    end

    it 'rejects a partially approved multi-secondary group' do
      values['identity_hash'] = task.send(:review_hash, values)
      other = values.merge('approved' => '', 'secondary_source_id' => '30', 'secondary_uuid' => 'other-uuid')
      other['identity_hash'] = task.send(:review_hash, other)

      expect do
        task.send(:validate_complete_group!, values['primary_uuid'], [values], [values, other])
      end.to raise_error(/Every row/)
    end

    it 'accepts a complete group with a stable review hash' do
      values['identity_hash'] = task.send(:review_hash, values)
      allow(task).to receive(:new_encounters).and_return([{ 'uuid' => 'encounter-uuid' }])

      expect do
        task.send(:validate_complete_group!, values['primary_uuid'], [values], [values])
      end.not_to raise_error
    end
  end

  describe 'voiding generated records' do
    it 'writes void audit columns without invoking model callbacks' do
      connection = double('connection')
      allow(connection).to receive(:columns).with('encounter').and_return(
        %w[encounter_id voided voided_by date_voided void_reason].map { |name| Struct.new(:name).new(name) }
      )
      allow(connection).to receive(:quote_table_name) { |value| "`#{value}`" }
      allow(connection).to receive(:quote_column_name) { |value| "`#{value}`" }
      allow(connection).to receive(:quote) do |value|
        value.is_a?(String) ? "'#{value}'" : value.to_s
      end
      executed_sql = nil
      allow(connection).to receive(:execute) { |sql| executed_sql = sql }
      task = described_class.new({}, connection: connection)
      task.instance_variable_set(:@operator_user_id, 99)

      task.send(:void_row!, 'encounter', 'encounter_id', 123)

      expect(executed_sql).to include('UPDATE `encounter`', '`voided`=1', '`voided_by`=99')
      expect(executed_sql).to include(described_class::VOID_REASON)
      expect(executed_sql).not_to match(/DELETE/i)
    end
  end
end
