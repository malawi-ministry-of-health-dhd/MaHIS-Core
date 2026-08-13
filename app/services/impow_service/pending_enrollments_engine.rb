# frozen_string_literal: true

module ImpowService
  # Service for managing pending enrollments to IMPOW (OS Program)
  # Handles listing of patients referred to OS but not yet enrolled
  class PendingEnrollmentsEngine
    DEFAULT_PER_PAGE = 10
    MAX_PER_PAGE = 20
    REFERRAL_WINDOW_DAYS = 7

    def initialize(program:, date: Date.today, page: 1, per_page: DEFAULT_PER_PAGE)
      @program = program
      @date = date
      @page = [page.to_i, 1].max
      @per_page = [[per_page.to_i, MAX_PER_PAGE].min, 1].max
    end

    # Get paginated pending enrollments
    def fetch_pending_enrollments
      result = find_referred_patients_with_pagination
      
      formatted_patients = result[:patients].map do |referral_data|
        format_referral_data(referral_data)
      end

      {
        data: formatted_patients,
        pagination: {
          current_page: @page,
          per_page: @per_page,
          total_count: result[:total_count],
          total_pages: (result[:total_count].to_f / @per_page).ceil
        }
      }
    end

    private

    # Find referred patients with database-level pagination
    # Returns the latest pending referral per patient (deduplicated)
    def find_referred_patients_with_pagination
      # Get "Referred to OS" state ID scoped to the program
      referred_state = ProgramWorkflowState.find_by_name_and_program(
        name: 'Referred to OS',
        program_id: @program.program_id
      )

      return { patients: [], total_count: 0 } unless referred_state

      # Get enrollment state IDs once, scoped to the program
      enrollment_states = ['Admitted In OTS', 'On SFS']
      enrollment_state_ids = enrollment_states.map do |state_name|
        ProgramWorkflowState.find_by_name_and_program(
          name: state_name,
          program_id: @program.program_id
        )&.program_workflow_state_id
      end.compact

      return { patients: [], total_count: 0 } if enrollment_state_ids.empty?

      # Calculate date range
      start_date = @date - REFERRAL_WINDOW_DAYS.days

      # Build base query conditions
      base_conditions = <<~SQL
        WHERE ps_ref.state = #{referred_state.program_workflow_state_id}
          AND ps_ref.start_date >= '#{start_date.strftime('%Y-%m-%d')}'
          AND ps_ref.start_date < '#{(@date + 1.day).strftime('%Y-%m-%d')}'
          AND ps_ref.voided = 0
          AND pp.voided = 0
          AND NOT EXISTS (
            SELECT 1 FROM patient_state ps_enroll
            WHERE ps_enroll.patient_program_id = pp.patient_program_id
              AND ps_enroll.state IN (#{enrollment_state_ids.join(',')})
              AND ps_enroll.start_date > ps_ref.start_date
              AND ps_enroll.voided = 0
          )
      SQL

      # First, get the count of unique patients with pending referrals
      count_sql = <<~SQL
        SELECT COUNT(DISTINCT pp.patient_id) AS total_count
        FROM patient_state ps_ref
        INNER JOIN patient_program pp ON pp.patient_program_id = ps_ref.patient_program_id
        #{base_conditions}
      SQL

      count_result = ActiveRecord::Base.connection.select_one(count_sql)
      total_count = count_result['total_count'].to_i

      return { patients: [], total_count: 0 } if total_count.zero?

      # Calculate pagination
      offset = (@page - 1) * @per_page

      # Query for patients with the latest pending referral (one per patient)
      # Join with patient details to avoid additional queries
      sql = <<~SQL
        SELECT 
          latest_ref.patient_id,
          latest_ref.referral_date,
          latest_ref.referring_program_id,
          pn.given_name,
          pn.family_name,
          per.gender,
          per.birthdate,
          pi.identifier AS national_id,
          prog.name AS program_name
        FROM (
          SELECT 
            pp.patient_id,
            MAX(ps_ref.start_date) AS referral_date,
            MAX(pp.program_id) AS referring_program_id
          FROM patient_state ps_ref
          INNER JOIN patient_program pp ON pp.patient_program_id = ps_ref.patient_program_id
          #{base_conditions}
          GROUP BY pp.patient_id
        ) latest_ref
        INNER JOIN patient p ON p.patient_id = latest_ref.patient_id
          AND p.voided = 0
        INNER JOIN person per ON per.person_id = p.patient_id
        LEFT JOIN person_name pn ON pn.person_id = p.patient_id
          AND pn.voided = 0
          AND pn.person_name_id = (
            SELECT MAX(pn2.person_name_id)
            FROM person_name pn2
            WHERE pn2.person_id = p.patient_id
              AND pn2.voided = 0
          )
        LEFT JOIN patient_identifier pi ON pi.patient_id = p.patient_id
          AND pi.voided = 0
          AND pi.identifier_type = (
            SELECT patient_identifier_type_id
            FROM patient_identifier_type
            WHERE name = 'National id'
            LIMIT 1
          )
          AND pi.patient_identifier_id = (
            SELECT MAX(pi2.patient_identifier_id)
            FROM patient_identifier pi2
            WHERE pi2.patient_id = p.patient_id
              AND pi2.voided = 0
              AND pi2.identifier_type = pi.identifier_type
          )
        LEFT JOIN program prog ON prog.program_id = latest_ref.referring_program_id
        ORDER BY latest_ref.referral_date DESC, latest_ref.patient_id ASC
        LIMIT #{@per_page} OFFSET #{offset}
      SQL

      results = ActiveRecord::Base.connection.select_all(sql)
      
      patients = results.map do |row|
        {
          patient_id: row['patient_id'],
          referral_date: row['referral_date'],
          referring_program_id: row['referring_program_id'],
          given_name: row['given_name'],
          family_name: row['family_name'],
          gender: row['gender'],
          birthdate: row['birthdate'],
          national_id: row['national_id'],
          program_name: row['program_name']
        }
      end

      { patients: patients, total_count: total_count }
    end

    def format_referral_data(referral_data)
      # Patient details already loaded from query - no additional queries needed
      {
        patientId: referral_data[:national_id] || 'N/A',
        name: format_patient_name_from_data(referral_data[:given_name], referral_data[:family_name]),
        genderAge: format_gender_age_from_data(referral_data[:gender], referral_data[:birthdate], referral_data[:patient_id]),
        referredFrom: referral_data[:program_name] || 'Unknown',
        referralDate: format_referral_date(referral_data[:referral_date]),
        patient_id: referral_data[:patient_id]
      }
    rescue StandardError => e
      Rails.logger.error("Error formatting referral data for patient #{referral_data[:patient_id]}: #{e.message}")
      raise # Re-raise to expose formatting errors instead of silently skipping patients
    end

    def format_patient_name_from_data(given_name, family_name)
      name = "#{given_name} #{family_name}".strip
      name.empty? ? 'N/A' : name
    end

    def format_gender_age_from_data(gender, birthdate, patient_id)
      return "#{gender} / N/A" unless birthdate

      # Calculate age directly from birthdate without loading Patient model
      age_in_days = (@date - birthdate.to_date).to_i
      age_in_months = (age_in_days / 30.4375).to_i
      age_in_years = age_in_months / 12

      if age_in_years >= 2
        "#{gender} / #{age_in_years}y"
      else
        "#{gender} / #{age_in_months}m"
      end
    rescue StandardError => e
      Rails.logger.error("Error calculating age for patient #{patient_id}: #{e.message}")
      "#{gender} / N/A"
    end

    def format_referral_date(date)
      return 'Unknown' unless date

      days_ago = (@date - date.to_date).to_i
      
      case days_ago
      when 0
        "Today, #{date.strftime('%I:%M %p')}"
      when 1
        "Yesterday, #{date.strftime('%I:%M %p')}"
      else
        "#{days_ago} days ago"
      end
    end
  end
end
