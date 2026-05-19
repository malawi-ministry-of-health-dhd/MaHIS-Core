# frozen_string_literal: true

class BedManagementService
  BED_EDITABLE_FIELDS = %i[
    bed_number
    bed_label
    location_id
    facility_id
    bed_status
    bed_type
    description
  ].freeze

  def create_bed(params, current_user)
    now = Time.now
    bed = Bed.new(filtered_params(params, BED_EDITABLE_FIELDS))
    bed.uuid = SecureRandom.uuid
    bed.creator = user_id_for(current_user)
    bed.date_created = now
    bed.retired = false
    bed.bed_status = Bed::ACTIVE_STATUS if bed.bed_status.blank?

    bed.save!
    bed
  end

  def update_bed(bed, params, current_user)
    bed.assign_attributes(filtered_params(params, BED_EDITABLE_FIELDS))
    bed.changed_by = user_id_for(current_user)
    bed.date_changed = Time.now

    bed.save!
    bed
  end

  def retire_bed(bed, retire_reason, current_user)
    raise InvalidParameterError, 'bed_already_occupied' if bed.occupied?

    bed.assign_attributes(
      retired: true,
      retired_by: user_id_for(current_user),
      date_retired: Time.now,
      retire_reason: retire_reason
    )

    bed.save!
    bed
  end

  def allocate_bed(params, current_user)
    BedAllocation.transaction do
      bed = lock_bed!(param_value(params, :bed_id))
      patient = lock_patient!(param_value(params, :patient_id))
      visit = find_visit!(param_value(params, :visit_id))

      ensure_bed_available!(bed)
      ensure_patient_available!(patient.patient_id)

      now = Time.now
      BedAllocation.create!(
        uuid: SecureRandom.uuid,
        bed_id: bed.bed_id,
        patient_id: patient.patient_id,
        visit_id: visit&.visit_id,
        allocated_at: param_value(params, :allocated_at) || now,
        allocation_status: BedAllocation::ACTIVE_STATUS,
        allocation_reason: param_value(params, :allocation_reason),
        notes: param_value(params, :notes),
        creator: user_id_for(current_user),
        date_created: now
      )
    end
  end

  def release_bed(allocation, release_reason, current_user)
    ensure_allocation_active!(allocation)

    allocation.release!(
      released_at: Time.now,
      release_reason: release_reason,
      changed_by: current_user
    )
  end

  def transfer_patient(current_allocation, new_bed_id, current_user, reason)
    BedAllocation.transaction do
      current_allocation = lock_allocation!(current_allocation)
      ensure_allocation_active!(current_allocation)

      new_bed = lock_bed!(new_bed_id)
      lock_patient!(current_allocation.patient_id)
      ensure_bed_available!(new_bed)

      released_at = Time.now
      current_allocation.transfer!(released_at: released_at, changed_by: current_user)
      ensure_patient_available!(current_allocation.patient_id)

      BedAllocation.create!(
        uuid: SecureRandom.uuid,
        bed_id: new_bed.bed_id,
        patient_id: current_allocation.patient_id,
        visit_id: current_allocation.visit_id,
        allocated_at: released_at,
        allocation_status: BedAllocation::ACTIVE_STATUS,
        allocation_reason: transfer_reason(current_allocation, new_bed, reason),
        creator: user_id_for(current_user),
        date_created: released_at
      )
    end
  end

  def discharge_patient_from_bed(allocation, current_user, reason)
    ensure_allocation_active!(allocation)

    allocation.discharge!(
      released_at: Time.now,
      changed_by: current_user,
      release_reason: reason
    )
  end

  private

  def filtered_params(params, fields)
    fields.each_with_object({}) do |field, attributes|
      value = param_value(params, field)
      attributes[field] = value unless value.nil?
    end
  end

  def param_value(params, key)
    params[key] || params[key.to_s]
  end

  def user_id_for(user_or_id)
    return user_or_id.user_id if user_or_id.respond_to?(:user_id)
    return user_or_id.id if user_or_id.respond_to?(:id)

    user_or_id
  end

  def lock_bed!(bed_id)
    Bed.unscoped.lock.find_by(bed_id: bed_id).tap do |bed|
      raise NotFoundError, 'bed_not_found' if bed.blank?
    end
  end

  def lock_patient!(patient_id)
    Patient.lock.find_by(patient_id: patient_id).tap do |patient|
      raise NotFoundError, 'patient_not_found' if patient.blank?
    end
  end

  def find_visit!(visit_id)
    return nil if visit_id.blank?

    Visit.find_by(visit_id: visit_id).tap do |visit|
      raise NotFoundError, 'visit_not_found' if visit.blank?
    end
  end

  def ensure_bed_available!(bed)
    raise InvalidParameterError, 'bed_retired' if bed.retired?
    raise InvalidParameterError, 'bed_not_active' unless bed.bed_status == Bed::ACTIVE_STATUS
    raise InvalidParameterError, 'bed_already_occupied' if active_allocation_for_bed?(bed.bed_id)
  end

  def ensure_patient_available!(patient_id)
    return unless active_allocation_for_patient?(patient_id)

    raise InvalidParameterError, 'patient_already_allocated'
  end

  def ensure_allocation_active!(allocation)
    raise InvalidParameterError, 'allocation_not_active' unless allocation&.active?
  end

  def lock_allocation!(allocation)
    BedAllocation.unscoped.lock.find_by(bed_allocation_id: allocation&.bed_allocation_id).tap do |locked_allocation|
      raise NotFoundError, 'allocation_not_found' if locked_allocation.blank?
    end
  end

  def active_allocation_for_bed?(bed_id)
    BedAllocation.unscoped.active.for_bed(bed_id).exists?
  end

  def active_allocation_for_patient?(patient_id)
    BedAllocation.unscoped.active.for_patient(patient_id).exists?
  end

  def transfer_reason(current_allocation, new_bed, reason)
    source = current_allocation.bed&.bed_number || current_allocation.bed_id
    destination = new_bed.bed_number || new_bed.bed_id
    [reason, "Transferred from bed #{source} to bed #{destination}"].compact.join(' - ')
  end
end
