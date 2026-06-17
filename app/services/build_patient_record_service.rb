# frozen_string_literal: true

module BuildPatientRecordService
  class << self
    include ModelUtils
    include BuildPatientRecordService::ObservationExtractor
    include BuildPatientRecordService::LabOrderService
    include BuildPatientRecordService::DrugService
    include BuildPatientRecordService::GuardianService
    include BuildPatientRecordService::PatientIdentifierService
    include BuildPatientRecordService::PersonInformationBuilder
    include BuildPatientRecordService::VaccineService
    include BuildPatientRecordService::VisitService

    # Main entry point for building patient records
    def build_patient_record(patient_id)
      validate_patient_id(patient_id)
      
      patient = find_patient(patient_id)
      return handle_patient_not_found(patient_id) unless patient

      build_complete_record(patient)
    rescue StandardError => e
      handle_error(e, patient_id)
    end


    def validate_patient_id(patient_id)
      raise ArgumentError, "Patient ID cannot be nil or empty" if patient_id.blank?
    end

    def find_patient(patient_id)
      Patient
        .includes(
          patient_identifiers: :type,
          person: [:names, :addresses, { person_attributes: :type }]
        )
        .find_by(patient_id: patient_id)
    end

    def handle_patient_not_found(patient_id)
      Rails.logger.warn("Patient not found: #{patient_id}")
      nil
    end

    def build_complete_record(patient)
      person = patient.person
      latest_encounter = find_latest_encounter(patient.patient_id)
      identifiers_by_type = patient_identifiers_by_type(patient)
      
      record = {
        **build_basic_info(patient, latest_encounter, identifiers_by_type),
        **build_personal_data(person, patient),
        **build_clinical_data(patient.patient_id),
        **build_administrative_data(patient),
        **build_status_fields
      }

      PatientRecordSearchFields.normalize!(record)
    end

    def find_latest_encounter(patient_id)
      Encounter.where(patient_id: patient_id)
               .select(:encounter_id, :patient_id, :location_id, :encounter_datetime, :date_changed)
               .order(encounter_datetime: :desc)
               .first
    end

    def build_basic_info(patient, latest_encounter, identifiers_by_type = nil)
      identifiers_by_type ||= patient_identifiers_by_type(patient)

      {
        patientID: patient.patient_id,
        ID: patient_identifier_from_map(identifiers_by_type, 3, patient.patient_id),
        nationalID: patient_identifier_from_map(identifiers_by_type, 28, patient.patient_id),
        NcdID: patient_identifier_from_map(identifiers_by_type, 31, patient.patient_id),
        ichisID: patient_identifier_from_map(identifiers_by_type, 10, patient.patient_id),
        TEI: extract_tei(patient, identifiers_by_type),
        program_id: '',
        provider_id: '',
        patient_identifiers: patient.patient_identifiers.as_json,
        location_id: latest_encounter&.location_id,
        encounter_datetime: latest_encounter&.encounter_datetime,
        encounter_date_changed: latest_encounter&.date_changed,
        sync_status: '',
        relationships: []
      }
    end

    def build_personal_data(person, patient)
      name = person&.names&.first
      address = person&.addresses&.first

      {
        personInformation: build(person, name, address, patient),
        guardianInformation: build_guardian_data(patient.patient_id),
        otherPersonInformation: build_other_person_info
      }
    end

    def build_clinical_data(patient_id)
      {
        vaccineAdministration: build_vaccine_administration_data(patient_id),
        labOrders: build_lab_orders_data(patient_id),
        MedicationOrder: build_medication_data(patient_id),
        observations: build_all_observations(patient_id, allowed_encounter_types = nil, status = "saved"),
        art_summary: build_art_summary(patient_id)
      }
    end

    def build_art_summary(patient_id)
      hiv_program_id = program_id_by_name('HIV Program')
      return {} unless hiv_program_id
      return {} unless PatientProgram.exists?(patient_id: patient_id, program_id: hiv_program_id)

      ArtService::PatientSummaryBuilder.new(patient_id).build
    rescue StandardError => e
      Rails.logger.error("Error building art_summary for patient #{patient_id}: #{e.message}")
      {}
    end

    def build_administrative_data(patient)
      {
        dispensations: build_dispensations_data(patient),
        visits: safe_get_visits(patient),
        activePrograms: fetch_active_programs(patient.patient_id)
      }
    end

    def build_status_fields
      {
        saveStatusPersonInformation: '',
        saveStatusGuardianInformation: '',
        saveStatusBirthRegistration: ''
      }
    end

    def build_guardian_data(patient_id)
      {
        saved: safe_get_guardians(patient_id),
        unsaved: []
      }
    end

    def build_other_person_info
      {
        nationalID: '',
        birthID: '',
        relationshipID: ''
      }
    end

    def extract_tei(patient, identifiers_by_type = nil)
      return '' if patient.blank?

      tei_from_person_attribute = begin
        person = patient.person
        if person&.association(:person_attributes)&.loaded?
          person.person_attributes.find do |attribute|
            %w[TEI trackedEntityInstance].include?(attribute.type&.name)
          end&.value
        else
          person&.person_attributes
                &.includes(:type)
                &.find { |attribute| %w[TEI trackedEntityInstance].include?(attribute.type&.name) }
                &.value
        end
      rescue StandardError => e
        Rails.logger.warn("Failed to fetch TEI from person attributes for patient #{patient.patient_id}: #{e.message}")
        nil
      end

      return tei_from_person_attribute if tei_from_person_attribute.present?

      tei_identifier = begin
        identifiers_by_type ||= patient_identifiers_by_type(patient)
        patient_identifier_type_ids_for(['TEI', 'Tracked Entity Instance']).lazy
                                                                      .map do |type_id|
          patient_identifier_from_map(identifiers_by_type, type_id, patient.patient_id)
        end.find(&:present?) || ''
      rescue StandardError => e
        Rails.logger.warn("Failed to fetch TEI from patient identifiers for patient #{patient.patient_id}: #{e.message}")
        ''
      end

      tei_identifier.to_s
    end

    def patient_identifier_type_ids_for(names)
      @patient_identifier_type_ids_by_name ||= {}
      names = Array(names)
      missing_names = names.reject { |name| @patient_identifier_type_ids_by_name.key?(name) }

      if missing_names.any?
        PatientIdentifierType.where(name: missing_names)
                             .pluck(:name, :patient_identifier_type_id)
                             .each do |name, type_id|
          @patient_identifier_type_ids_by_name[name] = type_id
        end
        missing_names.each { |name| @patient_identifier_type_ids_by_name[name] ||= nil }
      end

      names.filter_map { |name| @patient_identifier_type_ids_by_name[name] }
    end

    def program_id_by_name(name)
      @program_ids_by_name ||= {}
      return @program_ids_by_name[name] if @program_ids_by_name.key?(name)

      @program_ids_by_name[name] = Program.where(name: name).pick(:program_id)
    end

    def build_vaccine_administration_data(patient_id)
      {
        orders: [],
        obs: [],
        voided: []
      }
    end


    def build_lab_orders_data(patient_id)
      {
        saved: safe_get_lab_orders(patient_id),
        unsaved: [],
        voided: []
      }
    end

    def build_medication_data(patient_id)
      {
        saved: get_client_drug_orders(patient_id),
        unsaved: []
      }
    end

    def build_dispensations_data(patient)
      {
        saved: patient_service.find_program_drug_orders_awaiting_dispensation(patient, Date.today).as_json,
        unsaved: []
      }
    end


    def fetch_active_programs(patient_id)
      PatientProgram.unscoped
        .where(patient_id: patient_id, voided: 0)
        .includes(:patient_states, program: { concept: :concept_names })
        .map(&:as_json)
    end

    def handle_error(error, patient_id)
      Rails.logger.error("Error in build_patient_record for patient #{patient_id}: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
      
      # You might want to notify an error tracking service here
      # ErrorTrackingService.notify(error, { patient_id: patient_id })
      
      nil
    end
  end
end
