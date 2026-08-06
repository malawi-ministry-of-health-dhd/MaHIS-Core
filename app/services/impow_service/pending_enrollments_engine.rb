# frozen_string_literal: true

module ImpowService
  # Service for managing pending enrollments to IMPOW (OS Program)
  # Handles listing of patients referred to OS but not yet enrolled
  class PendingEnrollmentsEngine
    DEFAULT_PER_PAGE = 10
    MAX_PER_PAGE = 20
    REFERRAL_WINDOW_DAYS = 30

    # Stable program names — resolve IDs at runtime rather than hardcoding them
    OS_PROGRAM_NAMES = ['OS PROGRAM', 'ICCM/IMPOW PROGRAM'].freeze

    def initialize(program:, date: Date.today, page: 1, per_page: DEFAULT_PER_PAGE)
      @program = program
      @date = date.to_date rescue Date.today
      @page = [page.to_i, 1].max
      @per_page = [[per_page.to_i, MAX_PER_PAGE].min, 1].max
    end

    # Get paginated pending enrollments
    def fetch_pending_enrollments
      result = find_referred_patients_with_pagination

      {
        data: result[:patients],
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
    # Returns patients enrolled/referred to OS/IMPOW who have NOT been admitted to OTS/SFS yet
    def find_referred_patients_with_pagination
      os_program_ids = impow_program_ids

      # Enrollment state names in OS Program
      enrollment_states = ['Admitted In OTS', 'On SFS']
      enrollment_state_ids = enrollment_states.map do |state_name|
        ProgramWorkflowState.find_by_name_and_program(
          name: state_name,
          program_id: @program.program_id
        )&.program_workflow_state_id
      end.compact

      start_date = @date - REFERRAL_WINDOW_DAYS.days

      # Patient IDs that are CURRENTLY in an active admission state (OTS or SFS).
      # end_date IS NULL means the state is still open — discharged patients (end_date IS NOT NULL)
      # are intentionally excluded so they can re-appear if referred again.
      admitted_patient_ids = if enrollment_state_ids.any?
        PatientState.joins(:patient_program)
                    .where(patient_program: { program_id: os_program_ids, voided: 0 })
                    .where(state: enrollment_state_ids, voided: 0, end_date: nil)
                    .pluck(:patient_id)
      else
        []
      end

      # Base query: Patient programs enrolled/created within the referral window.
      # Both bounds are explicit: >= start_date prevents records older than REFERRAL_WINDOW_DAYS,
      # and <= @date prevents future-dated rows from leaking into the result.
      # Parentheses on the OR make grouping explicit when Rails combines with other clauses.
      base_query = PatientProgram.where(program_id: os_program_ids, voided: 0)
                                 .where(
                                   '(date_enrolled >= ? AND date_enrolled <= ?) OR (date_created >= ? AND date_created <= ?)',
                                   start_date, @date, start_date, @date
                                 )

      base_query = base_query.where.not(patient_id: admitted_patient_ids) if admitted_patient_ids.any?

      total_count = base_query.select(:patient_id).distinct.count
      return { patients: [], total_count: 0 } if total_count.zero?

      offset = (@page - 1) * @per_page

      # Build the admission exclusion fragment once for reuse.
      # Uses unqualified patient_id because this fragment goes inside the derived table
      # where the outer pp alias is not in scope.
      exclusion_fragment = admitted_patient_ids.any? ? "AND patient_id NOT IN (#{admitted_patient_ids.join(',')})" : ''

      # Derived-table query: group by patient_id to get the latest patient_program per patient,
      # then apply ORDER, LIMIT, and OFFSET entirely in the database.
      # This avoids loading the full cohort into Ruby memory and avoids MySQL's
      # restriction on LIMIT inside an IN subquery.
      paginated_sql = <<~SQL
        SELECT pp.*
        FROM patient_program pp
        INNER JOIN (
          SELECT patient_id, MAX(patient_program_id) AS latest_pp_id
          FROM patient_program
          WHERE program_id IN (#{os_program_ids.join(',')})
            AND voided = 0
            AND (
              (date_enrolled >= #{ActiveRecord::Base.connection.quote(start_date)} AND date_enrolled <= #{ActiveRecord::Base.connection.quote(@date)})
              OR
              (date_created >= #{ActiveRecord::Base.connection.quote(start_date)} AND date_created <= #{ActiveRecord::Base.connection.quote(@date)})
            )
            #{exclusion_fragment}
          GROUP BY patient_id
          ORDER BY MAX(COALESCE(date_enrolled, date_created)) DESC,
                   MAX(patient_program_id) DESC
          LIMIT #{@per_page} OFFSET #{offset}
        ) cohort ON cohort.latest_pp_id = pp.patient_program_id
        ORDER BY COALESCE(pp.date_enrolled, pp.date_created) DESC,
                 pp.patient_program_id DESC
      SQL

      pending_pps = PatientProgram.find_by_sql(paginated_sql)

      # Eager-load patient associations to avoid N+1 queries per row
      ActiveRecord::Associations::Preloader.new(
        records: pending_pps,
        associations: { patient: { person: :names, patient_identifiers: [] } }
      ).call

      national_id_type_ids = PatientIdentifierType.where(name: ['National id', 'Old national id']).pluck(:patient_identifier_type_id)

      patients = pending_pps.map do |pp_rec|
        # Use association instead of Patient.find to prevent extra queries and RecordNotFound exceptions
        pat = pp_rec.patient
        next unless pat && pat.person

        person = pat.person
        name_obj = person.names.reject { |n| n.voided == 1 || n.voided == true }.first
        full_name = name_obj ? "#{name_obj.given_name} #{name_obj.family_name}".strip : 'N/A'

        identifiers = pat.patient_identifiers.reject { |i| i.voided == 1 || i.voided == true }
        # Strictly look up National ID; return 'N/A' if missing instead of falling back to arbitrary identifier types
        nat_id = identifiers.find { |i| national_id_type_ids.include?(i.identifier_type) }&.identifier || 'N/A'

        # Find referring program (most recent non-OS enrollment; returns 'Unknown' if patient has no other program)
        other_program = PatientProgram.where(patient_id: pat.id, voided: 0)
                                      .where.not(program_id: os_program_ids)
                                      .order(date_enrolled: :desc, date_created: :desc)
                                      .first
        ref_program_name = other_program&.program&.name
        ref_label = ref_program_name ? ref_program_name.sub(/\s+PROGRAM$/i, '') : 'Unknown'

        {
          patientId: nat_id,
          name: full_name,
          genderAge: format_gender_age_from_data(person.gender, person.birthdate, pat.id),
          referredFrom: ref_label,
          referralDate: format_referral_date(pp_rec.date_enrolled || pp_rec.date_created),
          patient_id: pat.id
        }
      end.compact

      { patients: patients, total_count: total_count }
    end

    # Resolve IMPOW-related program IDs by name and memoize for this instance.
    # Raises if none are found so misconfigured environments fail loudly.
    def impow_program_ids
      @impow_program_ids ||= begin
        ids = Program.where(name: OS_PROGRAM_NAMES).pluck(:program_id)
        raise "No IMPOW programs found for names: #{OS_PROGRAM_NAMES.join(', ')}" if ids.empty?
        ids
      end
    end

    def format_gender_age_from_data(gender, birthdate, patient_id)
      return "#{gender} / N/A" unless birthdate

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
