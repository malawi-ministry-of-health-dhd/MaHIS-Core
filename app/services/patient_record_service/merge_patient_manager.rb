# app/services/patient_record_service/merge_patient_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class MergePatientManager < BaseSaver
    def merge_patients(patient_id, record)
      secondary_patient_id = record.dig(:otherPersonInformation, :secondaryPatientID)
      return ok unless secondary_patient_id

      patient_identifier = PatientIdentifier.find_by_identifier(secondary_patient_id)
      return fail("Secondary patient not found for identifier=#{secondary_patient_id}") unless patient_identifier

      primary_patient_ids = { "patient_id" => patient_id, "doc_id" => "" }
      secondary_patient_ids_list = [{ "patient_id" => patient_identifier.patient_id, "doc_id" => "" }]

      ActiveRecord::Base.transaction do
        service.merge_patients(primary_patient_ids, secondary_patient_ids_list)
        update_merged_potential_duplicates(primary_patient_ids, secondary_patient_ids_list)
      end

      ok
    rescue StandardError => e
      log_and_fail("Failed to merge patients", e)
    end

    private

    def service
      DdeService.new(program: program)
    end

    def program
      Program.find(14)
    end

    def update_merged_potential_duplicates(primary_patient_id, secondary_patient_ids)
      secondary_patient_ids.each do |secondary|
        PotentialDuplicate.where(
          patient_id_a: primary_patient_id[:patient_id],
          patient_id_b: secondary[:patient_id]
        ).or(
          PotentialDuplicate.where(
            patient_id_b: primary_patient_id[:patient_id],
            patient_id_a: secondary[:patient_id]
          )
        ).update_all(merge_status: true, updated_at: Time.now)
      end
    end
  end
end