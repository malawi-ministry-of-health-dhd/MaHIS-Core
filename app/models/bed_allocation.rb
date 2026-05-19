# frozen_string_literal: true

class BedAllocation < VoidableRecord
  self.table_name = :bed_mgmt_bed_allocation
  self.primary_key = :bed_allocation_id

  ACTIVE_STATUS = 'ACTIVE'
  RELEASED_STATUS = 'RELEASED'
  TRANSFERRED_STATUS = 'TRANSFERRED'
  DISCHARGED_STATUS = 'DISCHARGED'
  CANCELLED_STATUS = 'CANCELLED'
  ALLOCATION_STATUSES = [
    ACTIVE_STATUS,
    RELEASED_STATUS,
    TRANSFERRED_STATUS,
    DISCHARGED_STATUS,
    CANCELLED_STATUS
  ].freeze

  belongs_to :bed, class_name: 'Bed', foreign_key: :bed_id, primary_key: :bed_id, inverse_of: :bed_allocations
  belongs_to :patient, foreign_key: :patient_id, primary_key: :patient_id
  belongs_to :visit, foreign_key: :visit_id, primary_key: :visit_id, optional: true
  belongs_to :creator_user, -> { unscope(where: %i[deactivated_on location_id]) },
             class_name: 'User', foreign_key: :creator, primary_key: :user_id
  belongs_to :changed_by_user, -> { unscope(where: %i[deactivated_on location_id]) },
             class_name: 'User', foreign_key: :changed_by, primary_key: :user_id, optional: true
  belongs_to :voided_by_user, -> { unscope(where: %i[deactivated_on location_id]) },
             class_name: 'User', foreign_key: :voided_by, primary_key: :user_id, optional: true

  validates :uuid, presence: true, uniqueness: true
  validates :bed_id, :patient_id, :allocated_at, :allocation_status, :creator, presence: true
  validates :allocation_status, inclusion: { in: ALLOCATION_STATUSES }
  validate :bed_available_for_active_allocation, on: :create, if: :active_allocation?
  validate :released_at_not_before_allocated_at

  scope :not_voided, -> { where(voided: false) }
  scope :active, -> { where(allocation_status: ACTIVE_STATUS, released_at: nil, voided: false) }
  scope :active_current, -> { active }
  scope :for_patient, ->(patient_id) { where(patient_id: patient_id) }
  scope :for_visit, ->(visit_id) { where(visit_id: visit_id) }
  scope :for_bed, ->(bed_id) { where(bed_id: bed_id) }

  def active?
    allocation_status == ACTIVE_STATUS && released_at.nil? && !voided?
  end

  def release!(released_at:, release_reason:, changed_by:)
    update_release_state!(
      status: RELEASED_STATUS,
      released_at: released_at,
      release_reason: release_reason,
      changed_by: changed_by
    )
  end

  def transfer!(released_at:, changed_by:)
    update_release_state!(
      status: TRANSFERRED_STATUS,
      released_at: released_at,
      changed_by: changed_by
    )
  end

  def discharge!(released_at:, changed_by:)
    update_release_state!(
      status: DISCHARGED_STATUS,
      released_at: released_at,
      changed_by: changed_by
    )
  end

  def cancel!(void_reason:, voided_by:)
    transaction do
      now = Time.current
      user_id = user_id_for(voided_by)

      self.allocation_status = CANCELLED_STATUS
      self.voided = true
      self.void_reason = void_reason
      self.voided_by = user_id
      self.date_voided = now
      self.changed_by = user_id
      self.date_changed = now

      save!
    end
  end

  private

  def update_release_state!(status:, released_at:, changed_by:, release_reason: nil)
    transaction do
      self.allocation_status = status
      self.released_at = released_at
      self.release_reason = release_reason if release_reason.present?
      self.changed_by = user_id_for(changed_by)
      self.date_changed = Time.current

      save!
    end
  end

  def active_allocation?
    allocation_status == ACTIVE_STATUS && released_at.nil? && !voided?
  end

  def bed_available_for_active_allocation
    if bed.blank?
      errors.add(:bed, 'must exist')
      return
    end

    errors.add(:bed, 'is not active') unless bed.bed_status == Bed::ACTIVE_STATUS
    errors.add(:bed, 'is retired') if bed.retired?
    errors.add(:bed, 'already has an active allocation') if bed_has_active_allocation?
  end

  def bed_has_active_allocation?
    self.class.unscoped.active.for_bed(bed_id).exists?
  end

  def released_at_not_before_allocated_at
    return if released_at.blank? || allocated_at.blank?

    errors.add(:released_at, "can't be earlier than allocated_at") if released_at < allocated_at
  end

  def user_id_for(user_or_id)
    return user_or_id.user_id if user_or_id.respond_to?(:user_id)
    return user_or_id.id if user_or_id.respond_to?(:id)

    user_or_id
  end
end
