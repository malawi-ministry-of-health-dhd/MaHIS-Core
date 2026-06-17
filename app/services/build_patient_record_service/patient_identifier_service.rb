# frozen_string_literal: true
module BuildPatientRecordService
  module PatientIdentifierService
    extend self
    def patient_identifier(identifiers, identifier_type_id)
      return '' unless identifiers

      patient_identifier_from_map(
        patient_identifiers_by_type(identifiers),
        identifier_type_id,
        identifiers.patient_id
      )
    rescue StandardError => e
      Rails.logger.error("Error getting patient identifier for type #{identifier_type_id}: #{e.message}")
      ''
    end

    def patient_identifiers_by_type(patient)
      return {} unless patient

      patient.patient_identifiers.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |identifier, identifiers|
        next unless identifier.voided.to_i.zero?

        identifiers[identifier.identifier_type.to_i] << identifier
      end
    rescue StandardError => e
      Rails.logger.error("Error grouping patient identifiers for patient #{patient&.patient_id}: #{e.message}")
      {}
    end

    def patient_identifier_from_map(identifiers_by_type, identifier_type_id, patient_id = nil)
      matching = Array(identifiers_by_type[identifier_type_id.to_i])

      return '' if matching.empty?

      if matching.length > 1
        values = matching.map(&:identifier)
        Rails.logger.warn(
          "Patient #{patient_id} has #{matching.length} non-voided identifiers of type #{identifier_type_id}: #{values.join(', ')}"
        )
      end

      matching.max_by { |row| row.date_created || Time.at(0) }.identifier.to_s
    rescue StandardError => e
      Rails.logger.error("Error getting patient identifier for type #{identifier_type_id}: #{e.message}")
      ''
    end

  end
end
