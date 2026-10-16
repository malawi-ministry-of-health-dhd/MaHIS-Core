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

    it 'treats an approve-all rerun with no remaining groups as successful' do
      task = described_class.new({
        'APPLY' => '1', 'APPROVE_ALL' => '1',
        'CONFIRM' => described_class::CONFIRMATION, 'USER_ID' => '1'
      })
      allow(task).to receive(:automatically_approved_rows).and_return([])

      expect { task.send(:apply_review) }.not_to raise_error
    end

    it 'processes every discovered group in approve-all mode regardless of LIMIT' do
      connection = double('connection')
      allow(connection).to receive(:transaction).and_yield
      task = described_class.new({
        'APPLY' => '1', 'APPROVE_ALL' => '1', 'LIMIT' => '1',
        'CONFIRM' => described_class::CONFIRMATION, 'USER_ID' => '1'
      }, connection: connection)
      rows = [
        { 'approved' => 'yes', 'primary_uuid' => 'primary-one' },
        { 'approved' => 'yes', 'primary_uuid' => 'primary-two' }
      ]
      allow(task).to receive(:automatically_approved_rows).and_return(rows)
      allow(task).to receive(:lock_group_patients!)
      allow(task).to receive(:validate_complete_group!)
      allow(task).to receive(:write_csv)

      expect(task).to receive(:apply_group!).twice

      task.send(:apply_review)
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

  describe 'candidate discovery' do
    it 'detects exact ART duplicate merges from generated encounter copies when names were unchanged' do
      connection = double('connection')
      allow(connection).to receive(:quote) do |value|
        value.respond_to?(:strftime) ? "'#{value.strftime('%Y-%m-%d %H:%M:%S')}'" : "'#{value}'"
      end
      allow(connection).to receive(:quote_table_name) { |value| "`#{value}`" }
      task = described_class.new({}, connection: connection)
      captured_sql = nil
      allow(task).to receive(:select_all) do |sql|
        captured_sql = sql
        [{
          'primary_source_id' => 10,
          'primary_uuid' => 'primary-uuid',
          'secondary_source_id' => 20,
          'secondary_uuid' => 'secondary-uuid',
          'cleanup_at' => '2026-08-09 22:00:00'
        }]
      end

      rows = task.send(:candidate_pairs)

      expect(rows.length).to eq(1)
      expect(captured_sql).to include('exact_art_pairs', 'target_encounter.creator=1')
      expect(captured_sql).to include('original_uuid.uuid IS NULL')
      expect(captured_sql).to include('target_encounter.encounter_datetime <=> source_encounter.encounter_datetime')
    end
  end

  describe 'review enrichment' do
    it 'uses the earliest cleanup timestamp across every secondary in the group' do
      task = described_class.new({})
      group = [
        {
          'primary_source_id' => 10, 'primary_uuid' => 'primary-uuid',
          'secondary_source_id' => 20, 'secondary_uuid' => 'secondary-one',
          'cleanup_at' => '2026-08-09 10:00:00'
        },
        {
          'primary_source_id' => 10, 'primary_uuid' => 'primary-uuid',
          'secondary_source_id' => 30, 'secondary_uuid' => 'secondary-two',
          'cleanup_at' => '2026-08-07 10:00:00'
        }
      ]
      allow(task).to receive(:source_arv_numbers).and_return(10 => ['A'], 20 => ['B'], 30 => ['C'])
      earliest = Time.zone.parse('2026-08-07 10:00:00')
      expect(task).to receive(:new_encounters).with('primary-uuid', earliest).and_return([])
      allow(task).to receive(:recommend_owner).and_return(['primary-uuid', 'reason'])

      rows = task.send(:enrich_group, group)

      expect(rows.map { |row| row['cleanup_at'] }.uniq).to eq([earliest.iso8601])
    end

    it 'leaves a missing automatic owner for group-level validation' do
      task = described_class.new({})
      allow(task).to receive(:build_review_rows).and_return([{
        'primary_uuid' => 'primary-uuid',
        'new_encounter_count' => 1,
        'recommended_new_encounter_owner_uuid' => ''
      }])

      rows = task.send(:automatically_approved_rows)

      expect(rows.first['approved']).to eq('yes')
      expect(rows.first['new_encounter_owner_uuid']).to eq('')
    end
  end

  describe 'primary demographic preservation' do
    it 'does not restore the primary person, name, or address from the old snapshot' do
      task = described_class.new({})
      row = {
        'primary_source_id' => 10,
        'primary_uuid' => 'primary-uuid',
        'secondary_source_id' => 20,
        'secondary_uuid' => 'secondary-uuid',
        'new_encounter_uuids' => ''
      }
      allow(task).to receive(:validate_source_identity!)
      allow(task).to receive(:target_person_id).and_return(100)
      allow(task).to receive(:restore_primary_rows_voided_by_merge!)
      allow(task).to receive(:restore_patient_graph!).and_return(200)
      allow(task).to receive(:void_generated_copies!)
      allow(task).to receive(:reverse_cleanup_metadata!)

      expect(task).not_to receive(:restore_original_row!)

      task.send(:apply_group!, [row])
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

  describe 'moving new encounters' do
    it 'does not inspect or move visits when the reviewed owner is already the primary patient' do
      task = described_class.new({})
      cleanup_at = Time.zone.parse('2026-08-09 10:00:00')
      allow(task).to receive(:select_all).and_return([{
        'encounter_id' => 42,
        'uuid' => 'encounter-uuid',
        'patient_id' => 10,
        'voided' => 0,
        'creator' => 2,
        'date_created' => '2026-08-10 10:00:00',
        'visit_id' => 7
      }])
      allow(task).to receive(:source_uuid_exists?).and_return(false)

      expect(task).not_to receive(:ensure_visits_are_not_shared!)
      expect(task).not_to receive(:update_where)

      task.send(:move_new_encounters!, ['encounter-uuid'], 10, 10, cleanup_at)
    end
  end
end
