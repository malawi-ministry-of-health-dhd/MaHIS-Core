# frozen_string_literal: true

module ImpowService
  # Service for managing expected patients for clinic day
  # Handles patient listing, outcome retrieval, and status determination
  class ExpectedPatientsEngine
    DEFAULT_PER_PAGE = 10
    MAX_PER_PAGE = 100

    def initialize(program:, date: Date.today, page: 1, per_page: DEFAULT_PER_PAGE)
      @program = program
      @date = date
      @page = [page.to_i, 1].max # Ensure page is at least 1
      @per_page = [[per_page.to_i, MAX_PER_PAGE].min, 1].max # Clamp between 1 and MAX_PER_PAGE
    end

    # Get paginated expected patients for the clinic day with formatted data
    def fetch_expected_patients
      appointment_engine = AppointmentEngine.new(
        program: @program,
        patient: nil,
        retro_date: @date
      )

      all_patients = appointment_engine.expected_patients_for_clinic_day(@date)
      total_count = all_patients.size
      
      # Calculate pagination
      offset = (@page - 1) * @per_page
      paginated_patients = all_patients.slice(offset, @per_page) || []
      
      formatted_patients = paginated_patients.map do |patient|
        format_patient_data(patient)
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

    def format_patient_data(patient)
      {
        patientId: patient[:national_id],
        name: format_patient_name(patient[:given_name], patient[:family_name]),
        genderAge: format_gender_age(patient[:gender], patient[:birthdate], patient[:patient_id]),
        program: @program.name,
        outcome: get_current_outcome(patient[:patient_id]) || 'N/A',
        status: determine_patient_status(patient[:patient_id]),
        patient_id: patient[:patient_id]
      }
    end

    def get_current_outcome(patient_id)
      patient_program = PatientProgram.find_by(
        patient_id: patient_id,
        program_id: @program.program_id
      )
      
      return nil unless patient_program
      
      # Get current state using the model's method
      current_state = patient_program.current_state(@date)
      return nil unless current_state
      
      # Get the state name from program_workflow_state
      workflow_state = ProgramWorkflowState.find_by(program_workflow_state_id: current_state.state)
      workflow_state&.concept&.concept_names&.first&.name
    rescue StandardError => e
      Rails.logger.error("Error getting current outcome for patient #{patient_id}: #{e.message}")
      nil
    end

    def format_patient_name(given_name, family_name)
      "#{given_name} #{family_name}".strip
    end

    def format_gender_age(gender, birthdate, patient_id)
      return "#{gender} / N/A" unless birthdate

      patient = Patient.find(patient_id)
      age_in_months = patient.age_in_months(Date.today)
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

    def determine_patient_status(patient_id)
      patient = Patient.find(patient_id)
      
      # Check if anthropometry is done
      anthropometry_done = encounter_exists?(patient, 'VITALS') ||
                           encounter_exists?(patient, 'ANTHROPOMETRY')
      
      # Check if medical assessment is done
      assessment_done = encounter_exists?(patient, 'CONSULTATION') ||
                        encounter_exists?(patient, 'MEDICAL ASSESSMENT')
      
      # Check if dispensation is done
      dispensation_done = encounter_exists?(patient, 'TREATMENT') ||
                          encounter_exists?(patient, 'DISPENSING')

      if dispensation_done && anthropometry_done
        'Complete'
      elsif assessment_done && anthropometry_done
        'Assessment Done'
      elsif anthropometry_done
        'Anthropometry Done'
      else
        'Pending'
      end
    rescue StandardError => e
      Rails.logger.error("Error determining patient status for patient #{patient_id}: #{e.message}")
      'Pending'
    end

    def encounter_exists?(patient, encounter_type_name)
      encounter_type = EncounterType.find_by_name(encounter_type_name)
      return false unless encounter_type

      Encounter.where(
        patient_id: patient.patient_id,
        encounter_type: encounter_type.encounter_type_id,
        program_id: @program.program_id,
        voided: 0
      ).where(
        'DATE(encounter_datetime) = ?', @date.strftime('%Y-%m-%d')
      ).exists?
    end
  end
end
