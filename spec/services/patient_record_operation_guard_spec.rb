# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientRecordOperationGuard do
  before do
    delete_test_receipts
  end

  after do
    delete_test_receipts
  end

  def delete_test_receipts
    PatientRecordOperationReceipt.where(
      operation_type: 'lab_result.create',
      operation_id: %w[large-fbc-result stale-result]
    ).delete_all
  end

  it 'compacts large array target ids so operation receipts do not overflow' do
    result = described_class.run!(
      patient_id: 123,
      operation_type: 'lab_result.create',
      operation_id: 'large-fbc-result',
      target_type: 'LabResult'
    ) do
      (1..37).map { |id| { target_id: "213#{id.to_s.rjust(3, '0')}" } }
    end

    expect(result.receipt).to be_completed
    expect(result.receipt.target_type).to eq('LabResult')
    expect(result.receipt.target_id.length).to be <= 191
    expect(result.receipt.target_id).to start_with('count:37;')
  end

  it 'retries stale processing receipts instead of skipping forever' do
    receipt = PatientRecordOperationReceipt.create!(
      patient_id: 123,
      operation_type: 'lab_result.create',
      operation_id: 'stale-result',
      payload_hash: 'old',
      status: 'processing',
      started_at: 1.minute.ago
    )

    allow(described_class).to receive(:wait_for_processing_receipt).and_return(receipt)

    result = described_class.run!(
      patient_id: 123,
      operation_type: 'lab_result.create',
      operation_id: 'stale-result',
      payload: { value: 'new' },
      target_type: 'LabResult'
    ) do
      { target_id: 213_099 }
    end

    expect(result).to be_processed
    expect(result.receipt.reload).to be_completed
    expect(result.receipt.target_id).to eq('213099')
  end
end
