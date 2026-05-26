# frozen_string_literal: true

class BedManagementResponseBuilder
  OCCUPIED_STATUS = 'OCCUPIED'
  UNOCCUPIED_STATUS = 'UNOCCUPIED'

  class << self
    def bed(bed)
      allocation = bed.current_allocation

      {
        bed_id: bed.bed_id,
        uuid: bed.uuid,
        bed_number: bed.bed_number,
        bed_label: bed.bed_label,
        section_id: bed.section_id,
        location_id: bed.location_id,
        bed_status: bed.bed_status,
        bed_type: bed.bed_type,
        description: bed.description,
        occupancy_status: allocation.present? ? OCCUPIED_STATUS : UNOCCUPIED_STATUS,
        current_allocation: current_allocation(allocation),
        current_patient: current_patient(allocation&.patient),
        retired: bed.retired
      }
    end

    def allocation(allocation)
      person_name = allocation.patient&.person&.names&.max_by(&:date_created)
      section = allocation.bed&.section
      ward = section&.parent || allocation.bed&.location

      {
        bed_allocation_id: allocation.bed_allocation_id,
        uuid: allocation.uuid,
        bed_id: allocation.bed_id,
        patient_id: allocation.patient_id,
        visit_id: allocation.visit_id,
        allocated_at: allocation.allocated_at,
        released_at: allocation.released_at,
        allocation_status: allocation.allocation_status,
        allocation_reason: allocation.allocation_reason,
        release_reason: allocation.release_reason,
        notes: allocation.notes,
        voided: allocation.voided,
        given_name: person_name&.given_name,
        family_name: person_name&.family_name,
        bed_number: allocation.bed&.bed_number,
        section_name: section&.name,
        section_location_id: section&.location_id,
        ward_name: ward&.name,
        ward_location_id: ward&.location_id,
        visit_date_started: allocation.visit&.date_started
      }
    end

    private

    def current_allocation(allocation)
      return nil unless allocation

      {
        bed_allocation_id: allocation.bed_allocation_id,
        patient_id: allocation.patient_id,
        visit_id: allocation.visit_id,
        allocated_at: allocation.allocated_at
      }
    end

    def current_patient(patient)
      return nil unless patient

      {
        patient_id: patient.patient_id
      }
    end
  end
end
