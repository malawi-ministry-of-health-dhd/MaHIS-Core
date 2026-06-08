# frozen_string_literal: true
module BuildPatientRecordService
  module PatientIdentifierService
    extend self
    def patient_identifier(identifiers, identifier_type_id)
      return '' unless identifiers

      matching = identifiers.patient_identifiers.select do |identifier|
        identifier.identifier_type == identifier_type_id && identifier.voided.to_i.zero?
      end

      return '' if matching.empty?

      if matching.length > 1
        values = matching.map(&:identifier)
        Rails.logger.warn(
          "Patient #{identifiers.patient_id} has #{matching.length} non-voided identifiers of type #{identifier_type_id}: #{values.join(', ')}"
        )
      end

      matching.max_by { |row| row.date_created || Time.at(0) }.identifier.to_s
    rescue StandardError => e
      Rails.logger.error("Error getting patient identifier for type #{identifier_type_id}: #{e.message}")
      ''
    end
  end
end
