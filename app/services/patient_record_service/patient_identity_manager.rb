# app/services/patient_record_service/patient_identity_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class PatientIdentityManager < BaseSaver
    NCD_PROGRAM_ID = 32
    NCD_NUMBER_LOCK_NAME = 'mahis_ncd_number_allocation'
    NCD_NUMBER_LOCK_TIMEOUT = 10

    def save_person_information(record)
      return register_patient!(record) if record[:personInformation] && record[:saveStatusPersonInformation] == 'pending'

      existing_patient_id = record[:patientID]
      patient = Patient.find_by(patient_id: existing_patient_id) if existing_patient_id.present?
      patient ||= find_patient_by_record_uuid(record)

      # Offline/local records can retain a stale database patient_id after the
      # server database has been restored or the patient has been re-created.
      # Recover the canonical patient through the stable primary identifier
      # before deciding that this is a new registration.
      if patient.blank?
        patient = find_patient_by_identifier(extract_incoming_identifier(record))
        if patient.present?
          existing_patient_id = patient.patient_id
          record[:patientID] = existing_patient_id
        end
      end

      # No patient row backs this record yet. If it still carries person
      # information, it was never committed as 'pending' (e.g. a dependent
      # captured mid-registration) yet already syncs clinical data such as
      # orders and dispensation. Register it now so that data attaches to a real
      # patient instead of a phantom patient_id that later dereferences to nil.
      return register_patient!(record) if patient.blank? && record[:personInformation].present?

      # Do not pass a phantom patient_id into the clinical save operations.
      # SavePatientRecordService converts this nil into a controlled 400 error.
      return { patient_id: nil, id: extract_incoming_identifier(record) } if patient.blank?

      healed_identifier = ensure_primary_identifier(patient, extract_incoming_identifier(record), extract_location_id(record))
      record[:ID] = healed_identifier if healed_identifier.present?

      { patient_id: existing_patient_id, id: healed_identifier }
    end

    # Creates (or finds) the Person + Patient for a record and finalises its
    # registration: primary identifier, secondary ids, and the registration
    # encounter. Used both for records the client marked 'pending' and for
    # records that reached sync carrying clinical data but no backing patient.
    def register_patient!(record)
      incoming_identifier = extract_incoming_identifier(record)
      location_id         = extract_location_id(record)
      patient             = find_patient_by_identifier(incoming_identifier)

      if patient.blank?
        person_info = record[:personInformation].merge(uuid: PatientRecordIdentityService.record_uuid(record: record))
        person  = create_person(person_info)
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

      { patient_id: patient_id, id: identifier }
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

    # Retires historical DDE/NPID aliases after a user has found the patient by
    # an old barcode and confirmed that the replacement barcode was printed.
    # Values are required so a stale/offline request only targets the exact
    # aliases the user saw, never every identifier belonging to the patient.
    def void_legacy_dde_identifiers(patient_id, record)
      requested = Array(
        record[:voidLegacyDdeIdentifiers] || record['voidLegacyDdeIdentifiers']
      ).map { |identifier| identifier.to_s.strip }
       .reject(&:blank?)
       .uniq { |identifier| identifier.upcase }
      return ok if requested.empty?

      requested_values = requested.map(&:upcase)
      matching = PatientIdentifier.where(patient_id:, identifier_type: 2).select do |identifier|
        requested_values.include?(identifier.identifier.to_s.strip.upcase)
      end

      reason = 'Legacy DDE identifier retired after replacement barcode confirmation'
      PatientIdentifier.transaction do
        matching.each { |identifier| identifier.void(reason) }
      end

      record[:voidLegacyDdeIdentifiers] = []
      record['voidLegacyDdeIdentifiers'] = [] if record.respond_to?(:key?) && record.key?('voidLegacyDdeIdentifiers')
      changed_ok
    rescue StandardError => e
      log_and_fail("Failed to void legacy DDE identifiers", e)
    end

    # Completes a deferred identifier assignment. Offline clients submit an
    # NPID that was reserved from their local DDE pool; online clients submit
    # one allocated by the API. The operation is idempotent so listener retries
    # cannot give the patient a second identifier.
    def assign_dde_identifier(patient_id, record)
      request = record[:assignDdeIdentifier] || record['assignDdeIdentifier'] || {}
      npid = (request[:npid] || request['npid']).to_s.strip.upcase
      raise 'A reserved DDE NPID is required' if npid.blank?

      patient = Patient.includes(:patient_programs, :patient_identifiers, person: %i[names addresses person_attributes]).find(patient_id)
      existing = PatientIdentifier.unscoped.find_by(
        patient_id:,
        identifier_type: 3,
        identifier: npid,
        voided: 0
      )

      unless existing
        conflicting_owner = PatientIdentifier.unscoped.where(identifier_type: 3, identifier: npid, voided: 0)
                                               .where.not(patient_id:)
                                               .pick(:patient_id)
        raise "DDE NPID #{npid} is already assigned to patient #{conflicting_owner}" if conflicting_owner

        # DdeMergingService deliberately voids the patient's active NPID,
        # DDE document ID and legacy aliases while linking the new DDE person.
        # Snapshot both current and legacy NPIDs so every old barcode remains
        # searchable after that link is completed.
        previous_aliases = PatientIdentifier.unscoped.where(patient_id:, identifier_type: 2, voided: 0)
                                            .order(:date_created, :patient_identifier_id)
                                            .pluck(:identifier, :location_id)
        previous_current_npids = PatientIdentifier.unscoped.where(patient_id:, identifier_type: 3, voided: 0)
                                                   .order(:date_created, :patient_identifier_id)
                                                   .pluck(:identifier, :location_id)
        # Recreate the duplicated current NPID last so legacyDdeID (the indexed
        # scalar search alias) points to the identifier that led the user to
        # this reassignment workflow. legacyDdeIDs still carries every alias.
        previous_npids = previous_aliases + previous_current_npids
        if DdeService.dde_enabled?
          program = patient.patient_programs.order(:date_enrolled).first&.program ||
                    Program.find_by(program_id: record[:program_id] || record['program_id']) ||
                    Program.find(14)
          DdeService.new(program:).create_patient(patient, npid)
        else
          PatientIdentifier.create!(
            patient_id:,
            identifier_type: 3,
            identifier: npid,
            location_id: record[:location_id] || record['location_id'] || User.current&.location_id,
            preferred: 1
          )
        end

        current = PatientIdentifier.unscoped.find_by(patient_id:, identifier_type: 3, identifier: npid, voided: 0)
        raise "DDE did not assign requested NPID #{npid} to patient #{patient_id}" unless current

        PatientIdentifier.transaction do
          PatientIdentifier.unscoped.where(patient_id:, identifier_type: 3, voided: 0)
                           .where.not(patient_identifier_id: current.id)
                           .find_each { |identifier| identifier.void("Replaced by deferred DDE NPID #{npid}") }

          previous_npids.each do |old_npid, location_id|
            old_npid = old_npid.to_s.strip
            next if old_npid.blank? || old_npid.casecmp?(npid)
            next if PatientIdentifier.unscoped.exists?(
              patient_id:,
              identifier_type: 2,
              identifier: old_npid,
              voided: 0
            )

            PatientIdentifier.create!(
              patient_id:,
              identifier_type: 2,
              identifier: old_npid,
              location_id: location_id.presence || current.location_id,
              preferred: 0
            )
          end
        end
      end

      record[:ID] = npid
      record[:identifierAssignmentStatus] = 'assigned'
      record[:assignDdeIdentifier] = nil
      record['assignDdeIdentifier'] = nil if record.respond_to?(:key?) && record.key?('assignDdeIdentifier')
      changed_ok
    rescue StandardError => e
      log_and_fail('Failed to assign deferred DDE identifier', e)
    end

    def create_ncd_identifier(patient_id, record)
      ncd_id = record[:NcdID].presence || record['NcdID'].presence
      unsaved_ncd_id = record[:unsavedNcdID].presence || record['unsavedNcdID'].presence
      needs_ncd_id = truthy?(record[:needs_ncd_id] || record['needs_ncd_id'])
      location_id = extract_location_id(record)
      pending_ncd_id = ncd_id.to_s.strip.casecmp?('PENDING')
      return ok unless ncd_id == "-" || pending_ncd_id || needs_ncd_id || unsaved_ncd_id.present?

      requested_ncd_identifier = pending_ncd_id || needs_ncd_id ? "" : unsaved_ncd_id.to_s.strip

      existing_ncd_identifiers = PatientIdentifier.where(patient_id: patient_id, identifier_type: 31)
                                                 .order(date_created: :desc)
                                                 .to_a
      canonical_ncd_identifier = existing_ncd_identifiers.first

      # Patient already has a number and no *different* one was requested: keep it
      # and just void any per-patient duplicates (idempotent re-save).
      if canonical_ncd_identifier &&
         (requested_ncd_identifier.blank? || requested_ncd_identifier == canonical_ncd_identifier.identifier)
        existing_ncd_identifiers.drop(1).each do |duplicate_ncd_identifier|
          duplicate_ncd_identifier.void("Duplicate NCD number cleanup by #{User.current.username}")
        end
        record[:NcdID] = canonical_ncd_identifier.identifier
        record['NcdID'] = canonical_ncd_identifier.identifier
        record.delete(:needs_ncd_id)
        record.delete('needs_ncd_id')
        return changed_ok
      end

      # New assignment, or an explicit update to a different number. Either way go
      # through the locked, uniqueness-checked allocator. PatientIdentifierService
      # voids the patient's previous NCD identifier(s) when the value changes.
      resolved_ncd_identifier = assign_ncd_number(patient_id, requested_ncd_identifier, location_id)

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

    # Assign an NCD number to a patient under the allocation lock so two saves can
    # never persist the same number. `requested` is the desired number (blank →
    # auto-allocate); if it is already held by another patient (incl. voided) the
    # next available number is used instead. Creating the identifier voids the
    # patient's previous NCD number when the value changes (handles updates).
    # Returns the assigned identifier string.
    def assign_ncd_number(patient_id, requested, location_id)
      with_ncd_number_lock do
        candidate = requested.to_s.strip
        candidate = find_next_available_ncd_number(location_id) if candidate.blank?

        if ncd_number_taken_by_other?(candidate, patient_id)
          Rails.logger.warn(
            "[NCD] Requested NCD number #{candidate} already assigned; auto-assigning next available for patient #{patient_id}"
          )
          candidate = find_next_available_ncd_number(location_id)
        end

        PatientIdentifierService.create(
          patient_id:      patient_id,
          identifier:      candidate,
          identifier_type: 31,
          location_id:     location_id
        )
        candidate
      end
    end

    # True when the NCD number is already assigned to a different patient.
    # Uses `unscoped` so voided identifiers still count as taken — a voided NCD
    # number must never be reused. Kept consistent with find_next_available_ncd_number.
    def ncd_number_taken_by_other?(identifier, patient_id)
      return false if identifier.blank?

      PatientIdentifier.unscoped
                       .where(identifier: identifier, identifier_type: 31)
                       .where.not(patient_id: patient_id)
                       .exists?
    end

    # Serialize NCD number allocation across concurrent saves (including parallel
    # background jobs and web processes) using a MySQL server-wide named lock. The
    # lock is held only for the check-and-insert critical section and always
    # released. GET_LOCK returns 1 on success, 0 on timeout, NULL on error.
    def with_ncd_number_lock
      connection = ActiveRecord::Base.connection
      lock_name  = connection.quote(NCD_NUMBER_LOCK_NAME)
      acquired   = connection.select_value("SELECT GET_LOCK(#{lock_name}, #{NCD_NUMBER_LOCK_TIMEOUT})")
      raise "Timed out acquiring NCD number allocation lock" unless acquired.to_i == 1

      begin
        yield
      ensure
        connection.select_value("SELECT RELEASE_LOCK(#{lock_name})")
      end
    end

    def find_next_available_ncd_number(_location_id = nil)
      current_ncd_code = global_property("site_prefix")&.property_value
      raise 'Global property `site_prefix` not set' unless current_ncd_code

      "#{current_ncd_code}-NCD-#{PatientIdentifier.next_available_ncd_number(current_ncd_code)}"
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def global_property(name)
      GlobalProperty.find_by(property: name)
    end

    def extract_incoming_identifier(record)
      record[:ID].presence
    end

    def find_patient_by_record_uuid(record)
      record_uuid = PatientRecordIdentityService.record_uuid(record:)
      return nil if record_uuid.blank?

      Person.unscoped.find_by(uuid: record_uuid)&.patient
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
