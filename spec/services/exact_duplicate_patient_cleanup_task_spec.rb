# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExactDuplicatePatientCleanupTask do
  describe 'apply safeguards' do
    it 'requires the exact confirmation phrase' do
      expect do
        described_class.new({
          'APPLY' => '1',
          'CONFIRM' => 'MERGE',
          'APPROVAL_FILE' => __FILE__,
          'USER_ID' => '1',
          'PERMANENT_DELETE' => '1',
          'DELETE_CONFIRM' => HardDeleteUnsyncablePatientsTask::CONFIRMATION
        })
      end.to raise_error(/CONFIRM=MERGE_REVIEWED_EXACT_DUPLICATE_PATIENTS/)
    end

    it 'requires an approval file' do
      expect do
        described_class.new({
          'APPLY' => '1',
          'CONFIRM' => described_class::CONFIRMATION,
          'USER_ID' => '1',
          'PERMANENT_DELETE' => '1',
          'DELETE_CONFIRM' => HardDeleteUnsyncablePatientsTask::CONFIRMATION
        })
      end.to raise_error(/APPROVAL_FILE is required/)
    end

    it 'allows no approval file only with the unattended confirmation phrase' do
      expect do
        described_class.new({
          'APPLY' => '1',
          'UNATTENDED' => '1',
          'UNATTENDED_CONFIRM' => described_class::UNATTENDED_CONFIRMATION,
          'CONFIRM' => described_class::CONFIRMATION,
          'USER_ID' => '1',
          'PERMANENT_DELETE' => '1',
          'DELETE_CONFIRM' => HardDeleteUnsyncablePatientsTask::CONFIRMATION
        })
      end.not_to raise_error
    end

    it 'rejects unattended mode without its exact confirmation phrase' do
      expect do
        described_class.new({
          'APPLY' => '1',
          'UNATTENDED' => '1',
          'CONFIRM' => described_class::CONFIRMATION,
          'USER_ID' => '1',
          'PERMANENT_DELETE' => '1',
          'DELETE_CONFIRM' => HardDeleteUnsyncablePatientsTask::CONFIRMATION
        })
      end.to raise_error(/UNATTENDED_CONFIRM=MERGE_ALL_EXACT_DUPLICATES_WITHOUT_REVIEW/)
    end

    it 'requires an operator user' do
      expect do
        described_class.new({
          'APPLY' => '1',
          'CONFIRM' => described_class::CONFIRMATION,
          'APPROVAL_FILE' => __FILE__,
          'PERMANENT_DELETE' => '1',
          'DELETE_CONFIRM' => HardDeleteUnsyncablePatientsTask::CONFIRMATION
        })
      end.to raise_error(/USER_ID/)
    end

    it 'requires separate permanent-delete confirmation' do
      expect do
        described_class.new({
          'APPLY' => '1',
          'CONFIRM' => described_class::CONFIRMATION,
          'APPROVAL_FILE' => __FILE__,
          'USER_ID' => '1'
        })
      end.to raise_error(/PERMANENT_DELETE=1/)
    end
  end

  describe 'identifier conflicts' do
    subject(:task) { described_class.new({}) }

    it 'allows a shared identifier value of the same type' do
      primary = identifier_stats(3 => ['P123'])
      secondary = identifier_stats(3 => ['P123'])

      expect(task.send(:identifier_conflict_from_stats?, primary, secondary)).to be(false)
    end

    it 'flags different identifier values of the same type' do
      primary = identifier_stats(3 => ['P123'])
      secondary = identifier_stats(3 => ['P456'])

      expect(task.send(:identifier_conflict_from_stats?, primary, secondary)).to be(true)
    end
  end

  describe 'operator context' do
    it 'keeps the audit user but disables facility scoping during a database-wide merge' do
      operator = User.new(user_id: 123, location_id: 99)
      task = described_class.new({})
      user_scope = double('unscoped users')
      allow(User).to receive(:unscoped).and_return(user_scope)
      allow(user_scope).to receive(:find).with(0).and_return(operator)
      task.instance_variable_set(:@operator_user_id, 0)

      previous_user = User.current
      previous_location = Location.current
      current_values = nil

      task.send(:with_operator_context) do
        current_values = [User.current.id, User.current.location_id, Location.current]
      end

      expect(current_values).to eq([123, nil, nil])
      expect(operator.location_id).to eq('99')
      expect(User.current).to eq(previous_user)
      expect(Location.current).to eq(previous_location)
    end
  end

  describe 'unattended failure isolation' do
    it 'continues after one pair fails and reports the failed pair' do
      task = described_class.new({})
      failed_row = { 'primary_patient_id' => '1', 'secondary_patient_id' => '2' }
      successful_row = { 'primary_patient_id' => '3', 'secondary_patient_id' => '4' }
      primary = instance_double(Patient, id: 3)
      secondary = instance_double(Patient, id: 4)

      allow(task).to receive(:validate_approved_pair!) do |row|
        raise ActiveRecord::RecordInvalid if row == failed_row

        [primary, secondary]
      end
      allow(task).to receive(:merge_pair!).with(primary, secondary)

      merged, failures = task.send(:merge_rows!, [failed_row, successful_row], continue_on_error: true)

      expect(merged).to eq([[3, 4]])
      expect(failures.map { |failure| failure['secondary_patient_id'] }).to eq(['2'])
    end
  end

  describe 'DDE footprint suppression' do
    it 'does not enqueue new footprints for historical encounters copied by the merge' do
      merger = double('DDE merger')
      task = described_class.new({}, merger: merger)
      primary = instance_double(Patient, id: 10)
      secondary = instance_double(Patient, id: 20)
      allow(merger).to receive(:merge_local_patients)
      allow(task).to receive(:mark_potential_duplicates_merged!)

      task.send(:merge_pair!, primary, secondary)

      expect(merger).to have_received(:merge_local_patients).with(
        { 'patient_id' => 10, 'doc_id' => '' },
        { 'patient_id' => 20, 'doc_id' => '' },
        described_class::MERGE_TYPE,
        identifier_strategy: :keep_primary,
        suppress_dde_footprints: true
      )
    end

    it 'prevents an encounter callback from queueing a footprint while suppression is active' do
      previous = Encounter.suppress_dde_footprint_push
      Encounter.suppress_dde_footprint_push = true
      encounter = Encounter.new
      allow(GlobalProperty).to receive(:find_by_property)

      encounter.after_create

      expect(GlobalProperty).not_to have_received(:find_by_property)
    ensure
      Encounter.suppress_dde_footprint_push = previous
    end
  end

  describe 'pending hard-delete recovery' do
    it 'returns reviewed exact-merge audits whose secondary patient is still voided' do
      task = described_class.new({})
      relation = double('merge audit relation')
      allow(MergeAudit).to receive(:unscoped).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:joins).and_return(relation)
      allow(relation).to receive(:order).and_return(relation)
      allow(relation).to receive(:pluck).with(:primary_id, :secondary_id)
                                      .and_return([[10, 20], [10, 20], [30, 40]])

      expect(task.send(:pending_merged_secondary_pairs)).to eq([[10, 20], [30, 40]])
    end
  end

  describe 'performance mode' do
    it 'supports hard-delete-sized unattended batches' do
      task = described_class.new({ 'LIMIT' => '5000' })

      expect(task.instance_variable_get(:@apply_limit)).to eq(2_000)
    end

    it 'builds unattended approval rows without patient statistics' do
      task = described_class.new({})
      row = {
        'primary_patient_id' => 10,
        'secondary_patient_id' => 20,
        'given_name' => 'mary',
        'family_name' => 'banda',
        'gender' => 'F',
        'birthdate' => '2000-01-01',
        'village' => 'area 1',
        'traditional_authority' => 'ta',
        'district' => 'lilongwe'
      }

      result = task.send(:unattended_review_row, row)

      expect(result['approved']).to eq('yes')
      expect(result['allow_identifier_conflict']).to eq('yes')
      expect(result['identity_hash']).to be_present
    end
  end

  def identifier_stats(values)
    identifiers = Hash.new { |hash, type| hash[type] = Set.new }
    values.each { |type, entries| identifiers[type].merge(entries) }
    { identifiers: }
  end
end
