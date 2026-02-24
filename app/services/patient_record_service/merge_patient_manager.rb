module PatientRecordService
  class MergePatientManager < BaseSaver
    def merge_patients(patient_id, record)
    
      result = nil
      secondary_patient_id = record.dig(:otherPersonInformation, :secondaryPatientID)
      return false unless secondary_patient_id

      patient_identifier = PatientIdentifier.find_by_identifier(secondary_patient_id)

      primary_patient_ids = {
                      "patient_id" => patient_id,
                      "doc_id" => ""
                    }

      secondary_patient_ids_list = [
        { "patient_id" => patient_identifier.patient_id, "doc_id" => "" },
      ]
      
      ActiveRecord::Base.transaction do
        result = service.merge_patients(primary_patient_ids, secondary_patient_ids_list)
        update_merged_potential_duplicates(primary_patient_ids, secondary_patient_ids_list)
      end
      result
    end

    def service
        DdeService.new(program:)
    end

    def program
      Program.find(14)
    end

    def update_merged_potential_duplicates(primary_patient_id, secondary_patient_ids)
      secondary_patient_ids.each do |secondary_patient_id|
        PotentialDuplicate.where(patient_id_a: primary_patient_id[:patient_id],
                                  patient_id_b: secondary_patient_id[:patient_id])
                          .or(PotentialDuplicate.where(patient_id_b: primary_patient_id[:patient_id],
                                                        patient_id_a: secondary_patient_id[:patient_id]))
                          .update_all(merge_status: true, updated_at: Time.now)
      end
    end
  end
end  
  
 