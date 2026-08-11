# frozen_string_literal: true

# Keeps the technical identity of a patient record independent from mutable
# clinical identifiers such as the DDE NPID. Existing OpenMRS people already
# have a durable UUID, so no additional database column is required.
class PatientRecordIdentityService
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  PRIMARY_IDENTIFIER_TYPE = 3
  LEGACY_IDENTIFIER_TYPE = 2

  class << self
    def record_uuid(patient: nil, record: nil)
      supplied = patient&.person&.uuid
      supplied ||= uuid_from_document_id(record_value(record, :_id))
      normalize_uuid(supplied)
    end

    def document_id(patient: nil, record: nil)
      uuid = record_uuid(patient:, record:)
      uuid.presence
    end

    def apply!(record, patient: nil)
      uuid = record_uuid(patient:, record:)
      raise "Patient record UUID is missing for patient #{patient&.patient_id || record_value(record, :patientID)}" if uuid.blank?

      record[:_id] = uuid
      record
    end

    # Returns the presentation state for a batch without issuing one duplicate
    # lookup per patient. The earliest owner deterministically keeps a shared
    # NPID; all other owners are exported as pending assignment with that NPID
    # available only as a legacy search alias. MySQL remains unchanged until a
    # user confirms a replacement identifier.
    def assignment_states(patient_ids)
      ids = Array(patient_ids).map(&:to_i).select(&:positive?).uniq
      return {} if ids.empty?

      rows = active_primary_rows.where(patient_id: ids).to_a
      current_by_patient = rows.group_by(&:patient_id).transform_values { |owned| latest_identifier(owned) }
      values = current_by_patient.values.map { |row| row&.identifier.to_s.strip }.reject(&:blank?).uniq
      owners = active_primary_rows.where(identifier: values).to_a.group_by do |row|
        normalized_identifier(row.identifier)
      end

      current_by_patient.each_with_object({}) do |(patient_id, row), states|
        value = row&.identifier.to_s.strip
        shared_rows = owners[normalized_identifier(value)] || []
        keeper = shared_rows.min_by { |owner| identifier_order(owner) }
        states[patient_id.to_i] = {
          current_identifier: value,
          duplicate_owner_count: shared_rows.map(&:patient_id).uniq.length,
          pending: shared_rows.map(&:patient_id).uniq.length > 1 && keeper&.patient_id.to_i != patient_id.to_i
        }
      end
    end

    def assignment_state(patient_id)
      assignment_states([patient_id])[patient_id.to_i] || {
        current_identifier: '',
        duplicate_owner_count: 0,
        pending: false
      }
    end

    def normalize_uuid(value)
      value.to_s.strip
    end

    private

    def active_primary_rows
      PatientIdentifier.unscoped.where(identifier_type: PRIMARY_IDENTIFIER_TYPE, voided: 0)
    end

    def latest_identifier(rows)
      rows.max_by { |row| identifier_order(row) }
    end

    def identifier_order(row)
      [row.date_created || Time.at(0), row.patient_identifier_id.to_i, row.patient_id.to_i]
    end

    def normalized_identifier(value)
      value.to_s.strip.upcase
    end

    def uuid_from_document_id(value)
      text = value.to_s.strip
      return nil unless text.match?(UUID_PATTERN)

      text
    end

    def record_value(record, key)
      return nil unless record.respond_to?(:[])

      record[key] || record[key.to_s]
    end
  end
end
