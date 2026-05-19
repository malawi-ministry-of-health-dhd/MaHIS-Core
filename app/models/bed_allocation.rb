# frozen_string_literal: true

class BedAllocation < VoidableRecord
  self.table_name = :bed_mgmt_bed_allocation
  self.primary_key = :bed_allocation_id

  ACTIVE_STATUS = 'ACTIVE'

  belongs_to :bed, class_name: 'Bed', foreign_key: :bed_id, primary_key: :bed_id, inverse_of: :bed_allocations
  belongs_to :patient, foreign_key: :patient_id, primary_key: :patient_id
  belongs_to :visit, foreign_key: :visit_id, primary_key: :visit_id, optional: true

  scope :active_current, -> { where(allocation_status: ACTIVE_STATUS, released_at: nil, voided: false) }
end
