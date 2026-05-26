# frozen_string_literal: true

class Bed < RetirableRecord
  self.table_name = :bed_mgmt_bed
  self.primary_key = :bed_id

  ACTIVE_STATUS = 'ACTIVE'
  BED_STATUSES = %w[ACTIVE INACTIVE MAINTENANCE BLOCKED].freeze
  BED_TYPES = %w[GENERAL MATERNITY ICU ISOLATION PEDIATRIC EMERGENCY].freeze

  belongs_to :section, class_name: 'Location', foreign_key: :section_id, primary_key: :location_id
  belongs_to :location, foreign_key: :location_id, primary_key: :location_id, optional: true
  belongs_to :creator_user, -> { unscope(where: %i[deactivated_on location_id]) },
             class_name: 'User', foreign_key: :creator, primary_key: :user_id
  belongs_to :changed_by_user, -> { unscope(where: %i[deactivated_on location_id]) },
             class_name: 'User', foreign_key: :changed_by, primary_key: :user_id, optional: true
  belongs_to :retired_by_user, -> { unscope(where: %i[deactivated_on location_id]) },
             class_name: 'User', foreign_key: :retired_by, primary_key: :user_id, optional: true

  has_many :bed_allocations, class_name: 'BedAllocation',
                             foreign_key: :bed_id,
                             primary_key: :bed_id,
                             inverse_of: :bed

  validates :uuid, presence: true, uniqueness: true
  validates :bed_number, presence: true, uniqueness: { scope: :section_id }
  validates :section_id, :bed_status, :creator, presence: true
  validates :bed_status, inclusion: { in: BED_STATUSES }
  validates :bed_type, inclusion: { in: BED_TYPES }, allow_nil: true

  scope :not_retired, -> { where(retired: false) }
  scope :active, -> { not_retired.where(bed_status: ACTIVE_STATUS) }
  scope :for_section, ->(section_id) { where(section_id: section_id) }
  scope :available_for_allocation, lambda {
    active.where.not(
      bed_id: BedAllocation.active_current.select(:bed_id)
    )
  }
  scope :occupied, lambda {
    not_retired.where(
      bed_id: BedAllocation.active_current.select(:bed_id)
    )
  }

  def occupied?
    current_allocation.present?
  end

  def available_for_allocation?
    bed_status == ACTIVE_STATUS && !retired? && !occupied?
  end

  def current_allocation
    bed_allocations.active_current.order(allocated_at: :desc, bed_allocation_id: :desc).first
  end

  def current_patient
    current_allocation&.patient
  end
end
