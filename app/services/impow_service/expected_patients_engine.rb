# frozen_string_literal: true

module ImpowService
  # Service for managing expected patients for clinic day
  # Handles patient listing, outcome retrieval, and status determination
  class ExpectedPatientsEngine
    DEFAULT_PER_PAGE = 10
    MAX_PER_PAGE = 20

    # Encounter types for status determination (resolved once per request)
    STATUS_ENCOUNTER_TYPES = {
      anthropometry: ['VITALS', 'ANTHROPOMETRY'],
      assessment: ['CONSULTATION', 'MEDICAL ASSESSMENT'],
      dispensation: ['TREATMENT', 'DISPENSING']
    }.freeze

    def initialize(program:, date: Date.today, page: 1, per_page: DEFAULT_PER_PAGE)
      @program = program
      @date = date
      @page = [page.to_i, 1].max # Ensure page is at least 1
      @per_page = [[per_page.to_i, MAX_PER_PAGE].min, 1].max # Clamp between 1 and MAX_PER_PAGE
      @encounter_index = nil
    end

    # Get paginated expected patients for the clinic day with formatted data
    def fetch_expected_patients
      appointment_engine = AppointmentEngine.new(
        program: @program,
        patient: nil,
        retro_date: @date
      )

      # Fetch paginated patients and total count from database
      result = appointment_engine.expected_patients_for_clinic_day(
        @date, 
        page: @page, 
        per_page: @per_page
      )
      
      paginated_patients = result[:patients]
      total_count = result[:total_count]

      # Batch-load encounters for all patients on this page
      patient_ids = paginated_patients.map { |p| p[:patient_id] }
      build_encounter_index(patient_ids) unless patient_ids.empty?
      
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

    # Build an index of encounters for batch lookup: patient_id => Set of encounter type names
    def build_encounter_index(patient_ids)
      # Resolve encounter types once
      type_names = STATUS_ENCOUNTER_TYPES.values.flatten
      types = EncounterType.where(name: type_names).index_by(&:encounter_type_id)
      
      # Batch-load all encounters for paginated patients on @date
      rows = Encounter.where(
        patient_id: patient_ids,
        encounter_type: types.keys,
        program_id: @program.program_id,
        location_id: Location.current.location_id,
        voided: 0
      ).where(
        'DATE(encounter_datetime) = ?', @date.to_date
      ).pluck(:patient_id, :encounter_type)
      
      # Build index: patient_id => Set of encounter type names
      @encounter_index = rows.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |(pid, type_id), acc|
        acc[pid] << types[type_id].name.upcase
      end
    end

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

    def determine_patient_status(patient_id)
      # Use pre-loaded encounter index instead of querying per patient
      patient_encounters = @encounter_index[patient_id] || Set.new
      
      # Check if anthropometry is done
      anthropometry_done = STATUS_ENCOUNTER_TYPES[:anthropometry].any? { |type| patient_encounters.include?(type) }
      
      # Check if medical assessment is done
      assessment_done = STATUS_ENCOUNTER_TYPES[:assessment].any? { |type| patient_encounters.include?(type) }
      
      # Check if dispensation is done
      dispensation_done = STATUS_ENCOUNTER_TYPES[:dispensation].any? { |type| patient_encounters.include?(type) }

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
  end
end
