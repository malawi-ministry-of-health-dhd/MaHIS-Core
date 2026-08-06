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

      # Base query: Patient programs created for OS / IMPOW
      base_query = PatientProgram.where(program_id: os_program_ids, voided: 0)
                                 .where('date_enrolled >= ? OR date_created >= ?', start_date, start_date)

      base_query = base_query.where.not(patient_id: admitted_patient_ids) if admitted_patient_ids.any?

      total_count = base_query.select(:patient_id).distinct.count
      return { patients: [], total_count: 0 } if total_count.zero?

      offset = (@page - 1) * @per_page
      subquery_ids = base_query.group(:patient_id).pluck('MAX(patient_program_id)')
      pending_pps = PatientProgram.where(patient_program_id: subquery_ids)
                                 .order(date_enrolled: :desc, patient_program_id: :desc)
                                 .limit(@per_page)
                                 .offset(offset)

      national_id_type_id = PatientIdentifierType.find_by(name: 'National id')&.id

      patients = pending_pps.map do |pp_rec|
        pat = Patient.find(pp_rec.patient_id)
        person = pat.person
        name_obj = person.names.reject { |n| n.voided == 1 || n.voided == true }.first
        full_name = name_obj ? "#{name_obj.given_name} #{name_obj.family_name}".strip : 'N/A'

        identifiers = pat.patient_identifiers.reject { |i| i.voided == 1 || i.voided == true }
        nat_id = identifiers.find { |i| i.identifier_type == national_id_type_id }&.identifier || identifiers.first&.identifier || 'N/A'

        # Find referring program (e.g. HIV Program if patient has active HIV enrollment)
        other_programs = PatientProgram.where(patient_id: pat.id, voided: 0)
                                       .where.not(program_id: os_program_ids)
        ref_program_name = other_programs.first&.program&.name || 'HIV PROGRAM'
        ref_program_name = ref_program_name.sub(/\s+PROGRAM$/i, '')

        {
          patientId: nat_id,
          name: full_name,
          genderAge: format_gender_age_from_data(person.gender, person.birthdate, pat.id),
          referredFrom: ref_program_name,
          referralDate: format_referral_date(pp_rec.date_enrolled || pp_rec.date_created),
          patient_id: pat.id
        }
      end

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
