# frozen_string_literal: true

# ICCM Service
module IccmService
  # Aggregate counts for the ICCM/CMAM dashboard cards.
  class Dashboard
    DEFAULT_PROGRAM_ID = 42
    PROGRAM_NAME_CANDIDATES = ['ICCM/CMAM PROGRAM', 'ICCM/IMPOW PROGRAM', 'ICCM PROGRAM'].freeze
    DECISION_CONCEPT_NAME = 'ICCM case management decision'
    SAM_ENROLLED_CONCEPT_NAME = 'Admitted In OTS'
    REFERRAL_DECISION_NAMES = ['Refer', 'Stockout-Refer'].freeze
    HOME_TREATMENT_DECISION_NAME = 'Treat at home'
    YES_CONCEPT_NAME = 'Yes'

    def self.dashboard_stats(location_id: nil)
      danger_sign_ids = decision_patient_ids(DECISION_CONCEPT_NAME, REFERRAL_DECISION_NAMES, location_id)
      treated_at_home_ids = decision_patient_ids(DECISION_CONCEPT_NAME, [HOME_TREATMENT_DECISION_NAME], location_id)
      sam_enrolled_ids = decision_patient_ids(SAM_ENROLLED_CONCEPT_NAME, [YES_CONCEPT_NAME], location_id)

      {
        total_registered: total_registered_count(location_id, danger_sign_ids | treated_at_home_ids | sam_enrolled_ids),
        danger_signs: danger_sign_ids.size,
        treated_at_home: treated_at_home_ids.size,
        sam_enrolled: sam_enrolled_ids.size
      }
    end

    def self.program_id
      Program.where(name: PROGRAM_NAME_CANDIDATES).pick(:program_id) ||
        Program.where('name LIKE ?', '%ICCM%').pick(:program_id) ||
        DEFAULT_PROGRAM_ID
    end

    def self.total_registered_count(location_id, decision_patient_ids = [])
      scope = PatientProgram.where(program_id: program_id, voided: false)
      scope = scope.where(location_id: location_id) if location_id
      enrolled_ids = scope.distinct.pluck(:patient_id)
      (enrolled_ids | decision_patient_ids).size
    end

    def self.decision_patient_ids(question_name, answer_names, location_id)
      question_concept_id = ConceptName.where(name: question_name, voided: 0).pick(:concept_id)
      return [] unless question_concept_id

      answer_concept_ids = ConceptName.where(name: answer_names, voided: 0).pluck(:concept_id)
      return [] if answer_concept_ids.empty?

      scope = Observation.where(concept_id: question_concept_id, value_coded: answer_concept_ids, voided: false)
      scope = scope.where(location_id: location_id) if location_id
      scope.distinct.pluck(:person_id)
    end
  end
end

