# app/services/patient_record_service/patient_identity_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientIdentityManager < BaseSaver
    NCD_PROGRAM_ID = 32

    def save_person_information(record)
      if record[:personInformation] && record[:saveStatusPersonInformation] == 'pending'
        incoming_identifier = extract_incoming_identifier(record)
        location_id         = extract_location_id(record)
        patient             = find_patient_by_identifier(incoming_identifier)

        if patient.blank?
          person  = create_person(record[:personInformation])
          patient = create_patient(person.person_id, record)
        end

        patient_id = patient.patient_id
        identifier = ensure_primary_identifier(patient, incoming_identifier, location_id)
        other_person_information = record[:otherPersonInformation] || record['otherPersonInformation'] || {}

        created_ids = create_ids(other_person_information, patient_id, location_id)
        mark_ichis_enrolled_in_care(record) if created_ids[:ichis_id_saved]

        # MAHIS -> iCHIS identifier sync is handled asynchronously after save.

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

      healed_identifier = ensure_primary_identifier(patient, extract_incoming_identifier(record), extract_location_id(record))
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
      location_id = extract_location_id(record)
      PatientService.new.create_patient(program, person, '', record[:ID], location_id: location_id)
    end

    def create_ids(other_person_information, patient_id, location_id = nil)
      created_ids = { ichis_id_saved: false }
      return created_ids if other_person_information.blank?

      national_id = other_person_information_value(other_person_information, :nationalID)
      birth_id = other_person_information_value(other_person_information, :birthID)
      ichis_id = other_person_information_value(other_person_information, :ichisID)

      if national_id.present?
        PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: national_id,
          identifier_type: 28,
          location_id: location_id
        )
      end
      if birth_id.present?
        PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: birth_id,
          identifier_type: 23,
          location_id: location_id
        )
      end
      if ichis_id.present?
        created_ichis_identifier = PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: ichis_id,
          identifier_type: 10,
          location_id: location_id
        )
        created_ids[:ichis_id_saved] = created_ichis_identifier&.persisted?
      end

      created_ids
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
      changed_ok
    rescue StandardError => e
      log_and_fail("Failed to update person information", e)
    end

    def create_ncd_identifier(patient_id, record)
      ncd_id = record[:NcdID].presence || record['NcdID'].presence
      unsaved_ncd_id = record[:unsavedNcdID].presence || record['unsavedNcdID'].presence
      needs_ncd_id = truthy?(record[:needs_ncd_id] || record['needs_ncd_id'])
      location_id = extract_location_id(record)
      pending_ncd_id = ncd_id.to_s.strip.casecmp?('PENDING')
      return ok unless ncd_id == "-" || pending_ncd_id || needs_ncd_id || unsaved_ncd_id.present?

      existing_ncd_identifiers = PatientIdentifier.where(patient_id: patient_id, identifier_type: 31)
                                                 .order(date_created: :desc)
                                                 .to_a
      if existing_ncd_identifiers.present?
        canonical_ncd_identifier = existing_ncd_identifiers.first
        existing_ncd_identifiers.drop(1).each do |duplicate_ncd_identifier|
          duplicate_ncd_identifier.void("Duplicate NCD number cleanup by #{User.current.username}")
        end
        record[:NcdID] = canonical_ncd_identifier.identifier
        record['NcdID'] = canonical_ncd_identifier.identifier
        record.delete(:needs_ncd_id)
        record.delete('needs_ncd_id')
        return changed_ok
      end

      resolved_ncd_identifier = pending_ncd_id || needs_ncd_id ? "" : unsaved_ncd_id.to_s.strip
      resolved_ncd_identifier = find_next_available_ncd_number(location_id) if resolved_ncd_identifier.blank?

      PatientIdentifierService.create(
        patient_id:      patient_id,
        identifier:      resolved_ncd_identifier,
        identifier_type: 31,
        location_id:     location_id
      )
      record[:NcdID] = resolved_ncd_identifier
      record['NcdID'] = resolved_ncd_identifier
      record.delete(:needs_ncd_id)
      record.delete('needs_ncd_id')
      record.delete(:unsavedNcdID)
      record.delete('unsavedNcdID')

      changed_ok
    rescue StandardError => e
      log_and_fail("Failed to create NCD identifier", e)
    end

    def find_next_available_ncd_number(location_id)
      current_ncd_code = global_property("site_prefix")&.property_value
      raise 'Global property `site_prefix` not set' unless current_ncd_code

      type                           = PatientIdentifierType.find_by_name('NCD Number')
      raise 'Patient identifier type `NCD Number` not found' unless type

      current_ncd_number_identifiers = PatientIdentifier.where(identifier_type: type.patient_identifier_type_id)

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

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
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

    def ensure_primary_identifier(patient, incoming_identifier, location_id = nil)
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
        identifier_type: 3,
        location_id: location_id
      )

      return fallback_identifier if created_identifier&.persisted?

      creation_errors = created_identifier&.errors&.full_messages&.join(', ')
      raise "Failed to persist primary identifier #{fallback_identifier}: #{creation_errors.presence || 'unknown error'}"
    end

    def extract_location_id(record)
      record[:location_id].presence || record['location_id'].presence
    end

    def other_person_information_value(other_person_information, key)
      return nil unless other_person_information.respond_to?(:[])

      other_person_information[key].presence || other_person_information[key.to_s].presence
    end

    def mark_ichis_enrolled_in_care(record)
      program_id = record[:program_id].presence || record['program_id'].presence
      return unless program_id.to_i == NCD_PROGRAM_ID

      record[:send_ichis_enrolled_in_care] = true
    end
  end
end
