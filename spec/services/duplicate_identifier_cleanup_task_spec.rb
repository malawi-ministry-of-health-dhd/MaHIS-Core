# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DuplicateIdentifierCleanupTask do
  it 'requires explicit confirmation in apply mode' do
    expect do
      described_class.new({ 'APPLY' => '1', 'CONFIRM' => 'REPAIR' })
    end.to raise_error(/CONFIRM=REPAIR_REVIEWED_IDENTIFIER_DUPLICATES/)
  end

  it 'requires a separate DDE confirmation before requesting a type-3 identifier' do
    task = described_class.new({})
    patient = instance_double(Patient)

    expect do
      task.send(:request_fresh_dde!, patient)
    end.to raise_error(/DDE_CONFIRM=REQUEST_FRESH_DDE_IDENTIFIERS/)
  end


  it 'allows no approval file only with the unattended confirmation phrase' do
    expect do
      described_class.new({
        'APPLY' => '1',
        'UNATTENDED' => '1',
        'UNATTENDED_CONFIRM' => described_class::UNATTENDED_CONFIRMATION,
        'CONFIRM' => described_class::CONFIRMATION,
        'USER_ID' => '1'
      })
    end.not_to raise_error
  end

  it 'keeps one DDE reassignment per patient in an unattended batch' do
    task = described_class.new({})
    rows = [
      { 'action' => 'request_fresh_dde', 'target_patient_id' => '10' },
      { 'action' => 'request_fresh_dde', 'target_patient_id' => '10' },
      { 'action' => 'delete_extra_identifier', 'target_patient_id' => '10', 'identifier_type' => '3' },
      { 'action' => 'delete_extra_identifier', 'target_patient_id' => '20', 'identifier_type' => '3' },
      { 'action' => 'assign_reviewed_value', 'target_patient_id' => '30' }
    ]

    expect(task.send(:unattended_batch, rows)).to eq([rows[0], rows[3]])
  end
end
