# frozen_string_literal: true

module ImpowService
  # Provides various summary statistics for an IMPOW (nutrition) patient
  class PatientSummary
    NPID_TYPE = 'National id'
    IMPOW_NO_TYPE = 'IMPOW Number'
    FILING_NUMBER = 'Filing number'
    ARCHIVED_FILING_NUMBER = 'Archived filing number'
    IMPOW_PROGRAM_NAME = 'IMPOW Program'

    SECONDS_IN_MONTH = 2_592_000

    include ModelUtils

    attr_reader :patient, :date

    def initialize(patient, date)
      @patient = patient
      @date = date
    end

    def full_summary
      admission_date, program_duration = impow_period
      {
        patient_id: patient.patient_id,
        npid: npid || 'N/A',
        impow_number: impow_number || 'N/A',
        filing_number: filing_number || 'N/A',
        current_outcome:,
        residence:,
        program_duration: program_duration || 'N/A',
        current_treatment:,
        admission_date: admission_date&.strftime('%d/%m/%Y') || 'N/A',
        admission_criteria: admission_reason,
        current_muac: muac_value,
        weight_for_height_zscore: wfh_zscore,
        bilateral_pitting_oedema: has_oedema,
        nutritional_status: current_nutritional_status
      }
    end

    def identifier(identifier_type_name)
      identifier_type = PatientIdentifierType.where(name: identifier_type_name)

      PatientIdentifier.find_by(
        identifier_type: identifier_type.select(:patient_identifier_type_id),
        patient_id: patient.patient_id
      )&.identifier
    end

    def npid
      identifier(NPID_TYPE)
    end

    def impow_number
      identifier(IMPOW_NO_TYPE)
    end

    def residence
      address = patient.person.addresses[0]
      return 'N/A' unless address

      district = address.state_province || 'Unknown District'
      village = address.city_village || 'Unknown Village'
      "#{district}, #{village}"
    end

    ##
    # Returns the patient's current nutritional treatment (e.g., RUTF, Plumpy'Nut, etc.)
    def current_treatment
      # Get the most recent nutrition treatment/intervention for the patient
      treatment_concept = concept('Treatment provided')
      return 'N/A' unless treatment_concept

      obs = Observation.where(concept_id: treatment_concept.concept_id,
                              person_id: patient.patient_id)
                       .where('obs_datetime <= ?', date)
                       .order(obs_datetime: :desc)
                       .first

      return 'N/A' unless obs

      if obs.value_coded
        concept_name = ConceptName.unscoped.find_by(concept_id: obs.value_coded,
                                                    concept_name_type: 'FULLY_SPECIFIED')
        concept_name&.name || 'N/A'
      elsif obs.value_text
        obs.value_text
      else
        'N/A'
      end
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.error("Failed to retrieve patient current treatment: #{e}")
      'N/A'
    end

    def current_outcome
      patient_id = ActiveRecord::Base.connection.quote(patient.patient_id)
      quoted_date = ActiveRecord::Base.connection.quote(date)

      ActiveRecord::Base.connection.select_one(
        "SELECT patient_outcome(#{patient_id}, #{quoted_date}) as outcome"
      )['outcome'] || 'UNKNOWN'
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.error("Failed tor retrieve patient current outcome: #{e}:")
      'UNKNOWN'
    end

    def admission_reason
      concept = concept('Admission criteria') || concept('Reason for referral')
      return 'UNKNOWN' unless concept

      obs_list = Observation.where concept_id: concept.concept_id,
                                   person_id: patient.patient_id
      obs_list = obs_list.order(date_created: :desc).limit(1)
      return 'N/A' if obs_list.empty?

      obs = obs_list[0]

      if obs.value_coded
        reason_concept = ConceptName.unscoped.find_by(concept_id: obs.value_coded.to_i,
                                                      concept_name_type: 'FULLY_SPECIFIED')
        reason_concept&.name || 'N/A'
      elsif obs.value_text
        obs.value_text
      else
        'N/A'
      end
    end

    def impow_period
      # Get the date the patient was enrolled in the IMPOW program
      impow_program = Program.find_by(name: IMPOW_PROGRAM_NAME)
      return [nil, nil] unless impow_program

      enrollment = PatientProgram.where(patient_id: patient.patient_id,
                                        program_id: impow_program.program_id)
                                 .order(date_enrolled: :asc)
                                 .first

      return [nil, nil] unless enrollment

      admission_date = enrollment.date_enrolled.to_time

      duration = ((Time.now - admission_date) / SECONDS_IN_MONTH).to_i # Duration in months
      [admission_date, duration]
    rescue StandardError => e
      Rails.logger.error("Failed to retrieve IMPOW program period: #{e}")
      [nil, nil]
    end

    # Returns the most recent value_datetime for patient's observations of the
    # given concept
    def recent_value_datetime(concept_name)
      concept = ConceptName.find_by_name(concept_name)
      date = Observation.where(concept_id: concept.concept_id,
                               person_id: patient.patient_id)\
                        .order(obs_datetime: :desc)\
                        .first\
                        &.value_datetime
      return nil if date.blank?

      date
    end

    # Returns the most recent MUAC (Mid-Upper Arm Circumference) measurement
    def muac_value
      concept = concept('MUAC')
      return 'N/A' unless concept

      obs = Observation.where(concept_id: concept.concept_id,
                              person_id: patient.patient_id)
                       .where('obs_datetime <= ?', date)
                       .order(obs_datetime: :desc)
                       .first

      return 'N/A' unless obs

      value = obs.value_numeric || obs.value_text
      value ? "#{value} cm" : 'N/A'
    end

    # Returns the most recent Weight-for-Height Z-score
    def wfh_zscore
      concept = concept('Weight for height Z-score')
      return 'N/A' unless concept

      obs = Observation.where(concept_id: concept.concept_id,
                              person_id: patient.patient_id)
                       .where('obs_datetime <= ?', date)
                       .order(obs_datetime: :desc)
                       .first

      return 'N/A' unless obs

      obs.value_numeric&.round(2) || obs.value_text || 'N/A'
    end

    # Checks if patient has bilateral pitting oedema
    def has_oedema
      concept = concept('Bilateral pitting oedema') || concept('Oedema')
      return 'N/A' unless concept

      obs = Observation.where(concept_id: concept.concept_id,
                              person_id: patient.patient_id)
                       .where('obs_datetime <= ?', date)
                       .order(obs_datetime: :desc)
                       .first

      return 'N/A' unless obs

      if obs.value_coded
        answer = ConceptName.unscoped.find_by(concept_id: obs.value_coded,
                                              concept_name_type: 'FULLY_SPECIFIED')
        answer&.name || 'N/A'
      elsif obs.value_text
        obs.value_text
      else
        'N/A'
      end
    end

    # Returns the current nutritional status (SAM, MAM, Normal, etc.)
    def current_nutritional_status
      concept = concept('Nutritional status') || concept('Nutrition status')
      return 'UNKNOWN' unless concept

      obs = Observation.where(concept_id: concept.concept_id,
                              person_id: patient.patient_id)
                       .where('obs_datetime <= ?', date)
                       .order(obs_datetime: :desc)
                       .first

      return 'UNKNOWN' unless obs

      if obs.value_coded
        status = ConceptName.unscoped.find_by(concept_id: obs.value_coded,
                                              concept_name_type: 'FULLY_SPECIFIED')
        status&.name || 'UNKNOWN'
      elsif obs.value_text
        obs.value_text
      else
        'UNKNOWN'
      end
    end

    # Method of last resort in finding a patient's earliest admission date.
    #
    # Uses some cryptic SQL to come up with the value
    def earliest_admission_date
      patient_id = ActiveRecord::Base.connection.quote(patient.patient_id)

      impow_program = Program.find_by(name: IMPOW_PROGRAM_NAME)
      return nil unless impow_program

      program_id = ActiveRecord::Base.connection.quote(impow_program.program_id)

      row = ActiveRecord::Base.connection.select_one <<~SQL
        SELECT MIN(date_enrolled) as date
        FROM patient_program
        WHERE patient_id = #{patient_id}
          AND program_id = #{program_id}
          AND voided = 0
      SQL

      row['date']&.to_datetime
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.error("Failed to retrieve patient earliest admission date: #{e}")
      nil
    end

    def filing_number
      filing_number = identifier(FILING_NUMBER)
      return { number: filing_number || 'N/A', type: FILING_NUMBER } if filing_number

      filing_number = identifier(ARCHIVED_FILING_NUMBER)
      return { number: filing_number, type: ARCHIVED_FILING_NUMBER } if filing_number

      { number: 'N/A', type: 'N/A' }
    end

    def admission_date
      impow_period[0]
    end

    def name
      name = PersonName.where(person_id: patient.id)\
                       .order(:date_created)\
                       .first

      "#{name.given_name} #{name.family_name}"
    end
  end
end
