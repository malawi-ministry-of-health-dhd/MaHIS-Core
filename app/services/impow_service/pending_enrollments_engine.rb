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
      referred_patients = find_referred_patients
      total_count = referred_patients.size
      
      # Paginate
      offset = (@page - 1) * @per_page
      paginated_patients = referred_patients.slice(offset, @per_page) || []
      
      formatted_patients = paginated_patients.map do |referral_data|
        format_referral_data(referral_data)
      end

      {
        data: formatted_patients,
        pagination: {
          current_page: @page,
          per_page: @per_page,
          total_count: total_count,
          total_pages: (total_count.to_f / @per_page).ceil
        }
      }
    end

    private

    def find_referred_patients
      # Get "Referred to OS" state
      referred_state = ProgramWorkflowState.joins(:concept)
                                          .joins('INNER JOIN concept_name ON concept.concept_id = concept_name.concept_id')
                                          .where('concept_name.name = ?', 'Referred to OS')
                                          .first

      return [] unless referred_state

      # Find all patient states with "Referred to OS" within the last week
      start_date = @date - REFERRAL_WINDOW_DAYS.days
      
      referral_states = PatientState.where(state: referred_state.program_workflow_state_id)
                                   .where('start_date >= ? AND start_date <= ?', start_date, @date)
                                   .where(voided: 0)
                                   .order(start_date: :desc)
      
      # Filter out patients already enrolled
      referred_patients = []
      referral_states.each do |ref_state|
        patient_program = ref_state.patient_program
        next unless patient_program

        # Check if patient has been enrolled after the referral
        enrolled = patient_has_enrollment_after_referral?(patient_program, ref_state.start_date)
        
        unless enrolled
          referred_patients << {
            patient_id: patient_program.patient_id,
            referral_date: ref_state.start_date,
            referring_program_id: patient_program.program_id
          }
        end
      end

      referred_patients
    end

    def patient_has_enrollment_after_referral?(patient_program, referral_date)
      # Check if patient has "Admitted In OTS" or "On SFS" states after referral
      enrollment_states = ['Admitted In OTS', 'On SFS']
      
      enrollment_state_ids = ProgramWorkflowState.joins(:concept)
                                                 .joins('INNER JOIN concept_name ON concept.concept_id = concept_name.concept_id')
                                                 .where('concept_name.name IN (?)', enrollment_states)
                                                 .pluck(:program_workflow_state_id)

      return false if enrollment_state_ids.empty?

      # Check if patient has any of these states after referral date
      PatientState.where(patient_program: patient_program)
                 .where(state: enrollment_state_ids)
                 .where('start_date > ?', referral_date)
                 .where(voided: 0)
                 .exists?
    end

    def format_referral_data(referral_data)
      patient = Patient.find(referral_data[:patient_id])
      person = patient.person
      
      # Get referring program
      referring_program = Program.find_by(program_id: referral_data[:referring_program_id])
      
      {
        patientId: get_national_id(patient),
        name: format_patient_name(person),
        genderAge: format_gender_age(person, patient),
        referredFrom: referring_program&.name || 'Unknown',
        referralDate: format_referral_date(referral_data[:referral_date]),
        patient_id: patient.patient_id
      }
    rescue StandardError => e
      Rails.logger.error("Error formatting referral data for patient #{referral_data[:patient_id]}: #{e.message}")
      nil
    end

    def get_national_id(patient)
      identifier_type = PatientIdentifierType.find_by_name('National id')
      return 'N/A' unless identifier_type

      identifier = patient.patient_identifiers.find_by(
        identifier_type: identifier_type.patient_identifier_type_id,
        voided: 0
      )
      
      identifier&.identifier || 'N/A'
    end

    def format_patient_name(person)
      # Get the latest person_name (by person_name_id) to ensure deterministic results
      names = person.person_names.where(voided: 0).order(person_name_id: :desc).first
      return 'Unknown' unless names

      "#{names.given_name} #{names.family_name}".strip
    end

    def format_gender_age(person, patient)
      gender = person.gender
      return "#{gender} / N/A" unless person.birthdate

      age_in_months = patient.age_in_months(@date)
      age_in_years = age_in_months / 12

      if age_in_years >= 2
        "#{gender} / #{age_in_years}y"
      else
        "#{gender} / #{age_in_months}m"
      end
    rescue StandardError => e
      Rails.logger.error("Error calculating age for patient #{patient.patient_id}: #{e.message}")
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
