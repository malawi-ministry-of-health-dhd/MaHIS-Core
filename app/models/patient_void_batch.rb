# frozen_string_literal: true

# Receipt for a patient-level void. The marker it lends to every voided row's
# void_reason is what makes the void reversible: a restore matches on the marker
# and so can never resurrect a record that was voided for its own reason.
class PatientVoidBatch < ApplicationRecord
  MARKER_PATTERN = /\A\[PV:(\d+)\]/

  # void_reason is a varchar(255) on every voidable table, so the marker is kept
  # whole and the human reason is what gets trimmed.
  VOID_REASON_LIMIT = 255

  validates :patient_id, :reason, :date_voided, presence: true

  def self.marker_for(batch_id)
    "[PV:#{batch_id}]"
  end

  def self.batch_id_from(void_reason)
    void_reason.to_s[MARKER_PATTERN, 1]&.to_i
  end

  def marker
    self.class.marker_for(id)
  end

  def tagged_reason
    "#{marker} #{reason}"[0, VOID_REASON_LIMIT]
  end

  def restored?
    restored_at.present?
  end
end
