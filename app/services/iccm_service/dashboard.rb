# frozen_string_literal: true
module IccmService
  class Dashboard
    DEFAULT_PROGRAM_ID = 42
    PROGRAM_NAME_CANDIDATES = ['ICCM/CMAM PROGRAM', 'ICCM/IMPOW PROGRAM', 'ICCM PROGRAM'].freeze
    DECISION_CONCEPT_NAME = 'ICCM case management decision'
    SAM_ENROLLED_CONCEPT_NAME = 'Admitted In OTS'
    REFERRAL_DECISION_NAMES = ['Refer', 'Stockout-Refer'].freeze
    HOME_TREATMENT_DECISION_NAME = 'Treat at home'
    YES_CONCEPT_NAME = 'Yes'

    def self.dashboard_stats(location_id: nil, date: Date.today)
      month_start = date.to_date.beginning_of_month
      month_end   = month_start.next_month 

      decision_ids = fetch_decision_ids(location_id, month_start, month_end)

      danger_sign_ids     = decision_ids[:danger_sign]
      treated_at_home_ids = decision_ids[:treated_at_home]
      sam_enrolled_ids    = decision_ids[:sam_enrolled]

      {
        total_registered: total_registered_count(
          location_id, month_start, month_end,
          danger_sign_ids | treated_at_home_ids | sam_enrolled_ids
        ),
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

    def self.total_registered_count(location_id, month_start, month_end, decision_patient_ids = [])
      scope = PatientProgram.where(program_id: program_id, voided: false)
                            .where(date_enrolled: month_start...month_end)
      scope = scope.where(location_id: location_id) if location_id
      enrolled_ids = scope.distinct.pluck(:patient_id)
      (enrolled_ids | decision_patient_ids).size
    end

    def self.fetch_decision_ids(location_id, month_start, month_end)
      result = { danger_sign: [], treated_at_home: [], sam_enrolled: [] }

      location_clause = location_id ? 'AND o.location_id = :location_id' : ''

      sql = <<~SQL
        SELECT
          o.person_id,
          cn_q.name AS question_name,
          cn_a.name AS answer_name
        FROM obs o
        INNER JOIN concept_name cn_q
          ON cn_q.concept_id = o.concept_id AND cn_q.voided = 0
        INNER JOIN concept_name cn_a
          ON cn_a.concept_id = o.value_coded AND cn_a.voided = 0
        WHERE o.voided = 0
          AND o.obs_datetime >= :month_start
          AND o.obs_datetime <  :month_end
          #{location_clause}
          AND (
            (cn_q.name = :decision_name AND cn_a.name IN (:referral_names, :home_treatment_name))
            OR
            (cn_q.name = :sam_name AND cn_a.name = :yes_name)
          )
      SQL

      binds = {
        month_start: month_start,
        month_end: month_end,
        decision_name: DECISION_CONCEPT_NAME,
        referral_names: REFERRAL_DECISION_NAMES,
        home_treatment_name: HOME_TREATMENT_DECISION_NAME,
        sam_name: SAM_ENROLLED_CONCEPT_NAME,
        yes_name: YES_CONCEPT_NAME
      }
      binds[:location_id] = location_id if location_id

      sanitized_sql = ActiveRecord::Base.sanitize_sql_array([sql, binds])
      rows = ActiveRecord::Base.connection.select_all(sanitized_sql)

      rows.each do |row|
        person_id = row['person_id']
        if row['question_name'] == DECISION_CONCEPT_NAME
          if REFERRAL_DECISION_NAMES.include?(row['answer_name'])
            result[:danger_sign] << person_id
          elsif row['answer_name'] == HOME_TREATMENT_DECISION_NAME
            result[:treated_at_home] << person_id
          end
        elsif row['question_name'] == SAM_ENROLLED_CONCEPT_NAME && row['answer_name'] == YES_CONCEPT_NAME
          result[:sam_enrolled] << person_id
        end
      end

      result.transform_values(&:uniq)
    end
  end
end
