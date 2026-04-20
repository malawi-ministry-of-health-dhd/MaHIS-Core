# app/services/patient_record_service/patient_identity_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientIdentityManager < BaseSaver
    def save_person_information(record)
      if record[:personInformation] && record[:saveStatusPersonInformation] == 'pending'
        incoming_identifier = extract_incoming_identifier(record)
        patient             = find_patient_by_identifier(incoming_identifier)

        if patient.blank?
          person  = create_person(record[:personInformation])
          patient = create_patient(person.person_id, record)
        end

        patient_id = patient.patient_id
        identifier = ensure_primary_identifier(patient, incoming_identifier)
        other_person_information = record[:otherPersonInformation] || {}

        create_ids(other_person_information, patient_id)

        if other_person_information[:ichisID].present?
          tei = other_person_information[:TEI]
          ichis_data = { identifier: identifier, TEI: tei }
          FhirService.sendEMRIdToMediator(ichis_data)
        end

        create_encounter(patient_id, 5, record)

        record[:ID]                          = identifier
        record[:patientID]                   = patient_id
        record[:saveStatusPersonInformation] = 'complete'

        return { patient_id: patient_id, id: identifier }
      end

      existing_patient_id = record[:patientID]
      return { patient_id: existing_patient_id, id: record[:ID] } if existing_patient_id.blank?

      patient = Patient.unscoped.find_by(patient_id: existing_patient_id)
      return { patient_id: existing_patient_id, id: record[:ID] } if patient.blank?

      healed_identifier = ensure_primary_identifier(patient, extract_incoming_identifier(record))
      record[:ID] = healed_identifier if healed_identifier.present?

      { patient_id: existing_patient_id, id: healed_identifier }
    end

    def create_person(person_info)
      Person.transaction do
        person = person_service.create_person(person_info)
        person_service.create_person_name(person, person_info)
        person_service.create_person_address(person, person_info)
        person_service.create_person_attributes(person, person_info)
        person
      end
    end

    def create_patient(person_id, record)
      person  = Person.find(person_id)
      program = Program.find(record[:program_id])
      PatientService.new.create_patient(program, person, '', record[:ID])
    end

    def create_ids(other_person_information, patient_id)
      return if other_person_information.blank?

      if other_person_information[:nationalID].present?
        PatientIdentifierService.create(patient_id: patient_id, identifier: other_person_information[:nationalID], identifier_type: 28)
      end
      if other_person_information[:birthID].present?
        PatientIdentifierService.create(patient_id: patient_id, identifier: other_person_information[:birthID], identifier_type: 23)
      end
      if other_person_information[:ichisID].present?
        PatientIdentifierService.create(patient_id: patient_id, identifier: other_person_information[:ichisID], identifier_type: 10)
      end
    end

    def validate_ids(national_id, birth_id, _ichis_id)
      validate_identifier(national_id, type: :national) ||
        validate_identifier(birth_id, type: :birth)
    end

    def validate_identifier(id, type:)
      return true if id.nil? || id.empty?

      identifier_type_id = type == :national ? 28 : 23
      !identifier_exists?(identifier_type_id, id)
    end

    def identifier_exists?(type_id, id)
      return false unless type_id

      identifier_type = PatientIdentifierType.find(type_id)
      PatientService.new.find_patients_by_identifier(id, identifier_type).any?
    end

    def update_person_information(patient_id, record)
      return ok unless record[:personInformation] && record[:saveStatusPersonInformation] == 'edit'

      person = Person.find(patient_id)
      person_service.update_person(person, to_permitted_params(record[:personInformation]))
      ok
    rescue StandardError => e
      log_and_fail("Failed to update person information", e)
    end

    def create_ncd_identifier(patient_id, record)
        if record[:NcdID] == "-" || record[:unsavedNcdID].present?
          PatientIdentifierService.create(
            patient_id:      patient_id,
            identifier:      record[:unsavedNcdID] || find_next_available_ncd_number(record[:location_id]),
            identifier_type: 31
          )
        end

        ok
    rescue StandardError => e
      log_and_fail("Failed to create NCD identifier", e)
    end

    def find_next_available_ncd_number(location_id)
      current_ncd_code = global_property("site_prefix")&.property_value
      raise 'Global property `site_prefix` not set' unless current_ncd_code

      type                           = PatientIdentifierType.find_by_name('NCD Number')
      current_ncd_number_identifiers = PatientIdentifier.where(identifier_type: type, location_id: location_id)
      

      assigned_ncd_ids = current_ncd_number_identifiers&.filter_map do |identifier|
        Regexp.last_match(1).to_i if identifier.identifier =~ /#{current_ncd_code}-NCD- *(\d+)/
      end || []

      if assigned_ncd_ids.empty?
        next_available_number = 1
      else
        possible_number_range = global_property('ncd_number_range')&.property_value&.to_i || 100_000
        next_available_number = (Array.new(possible_number_range) { |i| i + 1 } - assigned_ncd_ids.sort).first
      end

      "#{current_ncd_code}-NCD-#{next_available_number}"
    end

    def global_property(name)
      GlobalProperty.find_by(property: name)
    end

    def extract_incoming_identifier(record)
      record[:ID].presence || record[:_id].presence
    end

    def find_patient_by_identifier(identifier)
      return nil if identifier.blank?

      patient_identifier = PatientIdentifier.find_by(identifier: identifier, identifier_type: 3) ||
                           PatientIdentifier.unscoped.find_by(identifier: identifier, identifier_type: 3, voided: 0)

      patient_identifier&.patient
    end

    def ensure_primary_identifier(patient, incoming_identifier)
      identifier = BuildPatientRecordService.patient_identifier(patient, 3).to_s.split(',').first&.strip
      return identifier if identifier.present?

      fallback_identifier = incoming_identifier.presence
      raise "Primary identifier missing for patient #{patient.patient_id}" if fallback_identifier.blank?

      existing_identifier = PatientIdentifier.unscoped.find_by(
        identifier: fallback_identifier,
        identifier_type: 3,
        voided: 0
      )

      if existing_identifier.present?
        return fallback_identifier if existing_identifier.patient_id == patient.patient_id

        raise "Identifier #{fallback_identifier} is already assigned to another patient"
      end

      created_identifier = PatientIdentifierService.create(
        patient_id: patient.patient_id,
        identifier: fallback_identifier,
        identifier_type: 3
      )

      return fallback_identifier if created_identifier&.persisted?

      creation_errors = created_identifier&.errors&.full_messages&.join(', ')
      raise "Failed to persist primary identifier #{fallback_identifier}: #{creation_errors.presence || 'unknown error'}"
    end
  end
end
