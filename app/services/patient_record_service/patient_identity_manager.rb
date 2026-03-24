# app/services/patient_record_service/patient_identity_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientIdentityManager < BaseSaver
    def save_person_information(record)
      if record[:personInformation] && record[:saveStatusPersonInformation] == 'pending'
        person     = create_person(record[:personInformation])
        patient    = create_patient(person.person_id, record)
        identifier = BuildPatientRecordService.patient_identifier(patient, 3)
        patient_id = person.person_id

        create_ids(record[:otherPersonInformation], patient_id)

        if record[:otherPersonInformation][:ichisID].present?
          tei       = record[:otherPersonInformation][:TEI]
          ichis_data = { identifier: identifier, TEI: tei }
          FhirService.sendEMRIdToMediator(ichis_data)
        end

        create_encounter(patient_id, 5, record)

        record[:ID]                          = identifier
        record[:patientID]                   = patient_id
        record[:saveStatusPersonInformation] = 'complete'

        return { patient_id: patient_id, id: identifier }
      end

      { patient_id: record[:patientID], id: record[:ID] }
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
      person_service.update_person(person, record[:personInformation].permit!)
      ok
    rescue StandardError => e
      log_and_fail("Failed to update person information", e)
    end

    def create_ncd_identifier(patient_id, record)
      return ok unless record[:NcdID].present?

      if record[:NcdID] == "-"
        PatientIdentifierService.create(
          patient_id:      patient_id,
          identifier:      find_next_available_ncd_number(record[:location_id]),
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
      current_ncd_number_identifiers = PatientIdentifier.where(identifier_type: type)

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
  end
end