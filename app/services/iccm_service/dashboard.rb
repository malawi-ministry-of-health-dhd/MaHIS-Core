# frozen_string_literal: true

# ICCM Service
module IccmService
  # Aggregate counts for the ICCM/CMAM dashboard cards.
  class Dashboard
    DEFAULT_PROGRAM_ID = 42
    DECISION_CONCEPT_NAME = 'ICCM case management decision'
    SAM_ENROLLED_CONCEPT_NAME = 'Admitted In OTS'
    REFERRAL_DECISION_NAMES = ['Refer', 'Stockout-Refer'].freeze
    HOME_TREATMENT_DECISION_NAME = 'Treat at home'
    YES_CONCEPT_NAME = 'Yes'

    def self.dashboard_stats(location_id: nil)
      {
        total_registered: total_registered_count(location_id),
        danger_signs: decision_patient_count(DECISION_CONCEPT_NAME, REFERRAL_DECISION_NAMES, location_id),
        treated_at_home: decision_patient_count(DECISION_CONCEPT_NAME, [HOME_TREATMENT_DECISION_NAME], location_id),
        sam_enrolled: decision_patient_count(SAM_ENROLLED_CONCEPT_NAME, [YES_CONCEPT_NAME], location_id)
      }
    end

    def self.program_id
      Program.find_by_name('ICCM/CMAM PROGRAM')&.id || DEFAULT_PROGRAM_ID
    end

    def self.total_registered_count(location_id)
      scope = PatientProgram.where(program_id: program_id, voided: false)
      scope = scope.where(location_id: location_id) if location_id
      scope.distinct.count(:patient_id)
    end

    def self.decision_patient_count(question_name, answer_names, location_id)
      question_concept_id = ConceptName.where(name: question_name, voided: 0).pick(:concept_id)
      return 0 unless question_concept_id

      answer_concept_ids = ConceptName.where(name: answer_names, voided: 0).pluck(:concept_id)
      return 0 if answer_concept_ids.empty?

      scope = Observation.where(concept_id: question_concept_id, value_coded: answer_concept_ids, voided: false)
      scope = scope.where(location_id: location_id) if location_id
      scope.distinct.count(:person_id)
    end
  end
end

