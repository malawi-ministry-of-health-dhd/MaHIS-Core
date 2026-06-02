# frozen_string_literal: true

class PatientRecordOperationReceipt < ApplicationRecord
  STATUSES = %w[processing completed failed].freeze

  validates :operation_type, :operation_id, :status, presence: true
  validates :operation_id, uniqueness: { scope: :operation_type }
  validates :status, inclusion: { in: STATUSES }

  def processing?
    status == 'processing'
  end

  def completed?
    status == 'completed'
  end

  def failed?
    status == 'failed'
  end
end
