# app/services/patient_record_service/guardian_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class GuardianManager < BaseSaver
    def manage_guardian(patient_id, record)
      initial_guardian_status = record[:saveStatusGuardianInformation]
      collected_errors = []

      updated_result = update_guardian_information(patient_id, record)
      collected_errors.concat(updated_result.errors) if updated_result.errors.any?

      created_result = create_guardian(patient_id, record)
      collected_errors.concat(created_result.errors) if created_result.errors.any?

      next_of_kin_result = create_next_of_kin(patient_id, record, initial_guardian_status)
      collected_errors.concat(next_of_kin_result.errors) if next_of_kin_result.errors.any?

      overall_success = updated_result.success? || created_result.success? || next_of_kin_result.success?
      OperationResult.new(success: overall_success, errors: collected_errors)
    end

    def update_guardian_information(patient_id, record)
      return ok unless record[:guardianInformation][:unsaved].present? &&
                       record[:saveStatusGuardianInformation] == 'edit'

      service           = PersonRelationshipService.new(Person.find(patient_id))
      relationship_data = service.find_relationships("")
      return ok unless relationship_data.present?

      person = Person.find(relationship_data[0].person_b)
      person_service.update_person(person, record[:guardianInformation][:unsaved][0].permit!)

      if relationship_data[0].relationship_id.present?
        relationship_type = RelationshipType.find(record[:otherPersonInformation][:relationshipID])
        service.void_relationship(relationship_data[0].relationship_id, "Guardian relationship updated")
        service.create_relationship(person, relationship_type)
      end

      ok
    rescue StandardError => e
      log_and_fail("Failed to update guardian information", e)
    end

    def create_guardian(patient_id, record)
      return ok unless record[:saveStatusGuardianInformation] == 'pending'
      return ok unless guardian_info_complete?(record)

      identity_manager = PatientRecordService::PatientIdentityManager.new
      guardian_data    = identity_manager.create_person(record[:guardianInformation][:unsaved][0])
      guardian_id      = guardian_data.person_id

      create_relation(
        guardian_id:          guardian_id,
        relationship_type_id: record[:otherPersonInformation][:relationshipID],
        person_id:            patient_id
      )

      record[:saveStatusGuardianInformation] = 'complete'
      ok
    rescue StandardError => e
      log_and_fail("Failed to save guardian information", e)
    end

    def create_relationship(record)
      return ok unless record[:relationships].present? && record[:relationships].is_a?(Array)

      collected_errors = []

      record[:relationships].each do |relationship|
        unless relationship[:guardianID].present? &&
               relationship[:patientID].present? &&
               relationship[:relationshipID].present?
          next
        end

        guardian_identifier = PatientIdentifier.find_by(identifier: relationship[:guardianID])
        guardian_id         = guardian_identifier&.patient_id

        patient_identifier = PatientIdentifier.find_by(identifier: relationship[:patientID])
        patient_id         = patient_identifier&.patient_id

        next unless guardian_id && patient_id

        existing = Relationship.find_by(
          person_a:     guardian_id,
          relationship: relationship[:relationshipID],
          person_b:     patient_id
        )
        next if existing.present?

        begin
          create_relation(
            guardian_id:          guardian_id,
            relationship_type_id: relationship[:relationshipID],
            person_id:            patient_id
          )
        rescue StandardError => e
          collected_errors << "Failed to create relationship guardian=#{relationship[:guardianID]}: #{e.message}"
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    end

    def create_next_of_kin(patient_id, record, initial_guardian_status = nil)
      return ok unless (initial_guardian_status || record[:saveStatusGuardianInformation]) == 'pending'
      return ok unless record[:nextOfKinInformation].present?

      next_of_kin    = record.dig(:nextOfKinInformation, :unsaved, 0)
      relationship_id = record.dig(:nextOfKinInformation, :relationshipID)
      return ok unless next_of_kin_complete?(next_of_kin, relationship_id)

      identity_manager = PatientRecordService::PatientIdentityManager.new
      next_of_kin_data = identity_manager.create_person(next_of_kin)
      next_of_kin_id   = next_of_kin_data.person_id

      create_relation(
        guardian_id:          next_of_kin_id,
        relationship_type_id: relationship_id,
        person_id:            patient_id
      )

      ok
    rescue StandardError => e
      log_and_fail("Failed to save next of kin information", e)
    end

    private

    def guardian_info_complete?(record)
      guardian        = record.dig(:guardianInformation, :unsaved, 0)
      relationship_id = record.dig(:otherPersonInformation, :relationshipID)

      guardian&.dig(:given_name).present? &&
        guardian&.dig(:family_name).present? &&
        relationship_id.present?
    end

    def next_of_kin_complete?(next_of_kin, relationship_id)
      next_of_kin&.dig(:given_name).present? &&
        next_of_kin&.dig(:family_name).present? &&
        relationship_id.present?
    end

    def create_relation(guardian_id:, relationship_type_id:, person_id:)
      relationship_type = RelationshipType.find(relationship_type_id)
      person            = Person.find(guardian_id)
      service           = PersonRelationshipService.new(Person.find(person_id))
      service.create_relationship(person, relationship_type)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error(e.message)
      raise # let callers handle and collect
    end
  end
end
