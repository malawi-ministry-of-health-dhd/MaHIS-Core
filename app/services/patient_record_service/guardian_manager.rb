# app/services/patient_record_service/guardian_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class GuardianManager < BaseSaver
    def manage_guardian(patient_id, record)
      updated = update_guardian_information(patient_id, record)
      created = create_guardian(patient_id, record)
      updated || created
    end

    def update_guardian_information(patient_id, record)
      return false unless record[:guardianInformation][:unsaved].present? &&
                          record[:saveStatusGuardianInformation] == 'edit'

      service = PersonRelationshipService.new Person.find(patient_id)
      relationship_data = service.find_relationships("")
      return false unless relationship_data.present?

      person = Person.find(relationship_data[0].person_b)
      person_service.update_person(person, record[:guardianInformation][:unsaved][0].permit!)

      if relationship_data[0].relationship_id.present?
        relationship_type = RelationshipType.find record[:otherPersonInformation][:relationshipID]
        service.void_relationship relationship_data[0].relationship_id, "Guardian relationship updated"
        service.create_relationship person, relationship_type
      end

      true
    rescue StandardError => e
      log_error("Failed to update guardian information", e)
      false
    end

    def create_guardian(patient_id, record)
      return false unless record[:saveStatusGuardianInformation] == 'pending'
      return false unless guardian_info_complete?(record)

      guardian_data = person_service.create_person(record[:guardianInformation][:unsaved][0])
      guardian_id = guardian_data.person_id

      create_relation(
        guardian_id: guardian_id,
        relationship_type_id: record[:otherPersonInformation][:relationshipID],
        person_id: patient_id
      )
      record[:saveStatusGuardianInformation] = 'complete'
      true
    rescue StandardError => e
      log_error("Failed to save guardian information", e)
      false
    end

    def guardian_info_complete?(record)
      guardian = record.dig(:guardianInformation, :unsaved, 0)
      relationship_id = record.dig(:otherPersonInformation, :relationshipID)

      guardian&.dig(:given_name).present? &&
        guardian&.dig(:family_name).present? &&
        relationship_id.present?
    end

    def create_relation(guardian_id:, relationship_type_id:, person_id:)
      relationship_type = RelationshipType.find relationship_type_id
      person = Person.find guardian_id
      service = PersonRelationshipService.new Person.find(person_id)
      service.create_relationship person, relationship_type
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error(e.message)
    end
  end
end
