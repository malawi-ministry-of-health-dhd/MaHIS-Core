# frozen_string_literal: true

module ImpowService
  # Service for managing batch dispensation
  # Handles listing patients who need dispensation for the clinic day:
  # - Patients who have done prescription/treatment in the past 2 days
  # - BUT have NOT done dispensing on that same visit
  class BatchDispensationEngine
    DEFAULT_PER_PAGE = 20
    MAX_PER_PAGE = 100

    def initialize(program:, date: Date.today, page: 1, per_page: DEFAULT_PER_PAGE)
      @program = program
      @date = date
      @page = [page.to_i, 1].max
      @per_page = [[per_page.to_i, MAX_PER_PAGE].min, 1].max
      @location_id = Location.current.location_id
    end

    # Get patients who need dispensation:
    # 1. Patients with prescription/treatment in past 2 days
    # 2. BUT no dispensing on that same visit
    def fetch_patients_awaiting_dispensation
      # Get total count with separate COUNT query
      total_count = count_patients_needing_dispensation
      
      # Get paginated results using database-level LIMIT and OFFSET
      offset = (@page - 1) * @per_page
      patients = find_patients_needing_dispensation(limit: @per_page, offset: offset)
      
      formatted_patients = patients.map do |patient_data|
        format_patient_data(patient_data)
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

    def count_patients_needing_dispensation
      encounter_type_ids = get_encounter_type_ids
      return 0 if encounter_type_ids[:treatment].empty? || encounter_type_ids[:dispensing].empty?

      two_days_ago = @date - 2.days
      treatment_ids = encounter_type_ids[:treatment].join(',')
      dispensing_ids = encounter_type_ids[:dispensing].join(',')

      sql = <<~SQL
        SELECT COUNT(DISTINCT p.patient_id) AS total
        FROM encounter treatment
        INNER JOIN patient p ON p.patient_id = treatment.patient_id AND p.voided = 0
        WHERE treatment.encounter_type IN (#{treatment_ids})
          AND treatment.program_id = #{@program.program_id}
          AND treatment.location_id = #{@location_id}
          AND treatment.voided = 0
          AND DATE(treatment.encounter_datetime) BETWEEN '#{two_days_ago}' AND '#{@date}'
          AND treatment.encounter_id = (
            SELECT e.encounter_id
            FROM encounter e
            WHERE e.patient_id = p.patient_id
              AND e.encounter_type IN (#{treatment_ids})
              AND e.program_id = #{@program.program_id}
              AND e.location_id = #{@location_id}
              AND e.voided = 0
              AND DATE(e.encounter_datetime) BETWEEN '#{two_days_ago}' AND '#{@date}'
            ORDER BY e.encounter_datetime DESC
            LIMIT 1
          )
          AND NOT EXISTS (
            SELECT 1 FROM encounter dispense
            WHERE dispense.patient_id = p.patient_id
              AND dispense.program_id = #{@program.program_id}
              AND dispense.location_id = #{@location_id}
              AND dispense.encounter_type IN (#{dispensing_ids})
              AND dispense.voided = 0
              AND DATE(dispense.encounter_datetime) = DATE(treatment.encounter_datetime)
          )
      SQL

      result = ActiveRecord::Base.connection.select_one(sql)
      result['total'].to_i
    rescue StandardError => e
      Rails.logger.error("Error counting patients needing dispensation: #{e.message}")
      0
    end

    def find_patients_needing_dispensation(limit:, offset:)
      encounter_type_ids = get_encounter_type_ids
      return [] if encounter_type_ids[:treatment].empty? || encounter_type_ids[:dispensing].empty?

      two_days_ago = @date - 2.days
      treatment_ids = encounter_type_ids[:treatment].join(',')
      dispensing_ids = encounter_type_ids[:dispensing].join(',')

      sql = <<~SQL
        SELECT 
          p.patient_id,
          pn.given_name,
          pn.family_name,
          per.gender,
          per.birthdate,
          pi.identifier AS national_id,
          treatment.encounter_datetime AS treatment_datetime,
          DATE(treatment.encounter_datetime) AS visit_date
        FROM encounter treatment
        INNER JOIN patient p ON p.patient_id = treatment.patient_id
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
        WHERE treatment.encounter_type IN (#{treatment_ids})
          AND treatment.program_id = #{@program.program_id}
          AND treatment.location_id = #{@location_id}
          AND treatment.voided = 0
          AND DATE(treatment.encounter_datetime) BETWEEN '#{two_days_ago}' AND '#{@date}'
          AND treatment.encounter_id = (
            SELECT e.encounter_id
            FROM encounter e
            WHERE e.patient_id = p.patient_id
              AND e.encounter_type IN (#{treatment_ids})
              AND e.program_id = #{@program.program_id}
              AND e.location_id = #{@location_id}
              AND e.voided = 0
              AND DATE(e.encounter_datetime) BETWEEN '#{two_days_ago}' AND '#{@date}'
            ORDER BY e.encounter_datetime DESC
            LIMIT 1
          )
          AND NOT EXISTS (
            SELECT 1 FROM encounter dispense
            WHERE dispense.patient_id = p.patient_id
              AND dispense.program_id = #{@program.program_id}
              AND dispense.location_id = #{@location_id}
              AND dispense.encounter_type IN (#{dispensing_ids})
              AND dispense.voided = 0
              AND DATE(dispense.encounter_datetime) = DATE(treatment.encounter_datetime)
          )
        ORDER BY treatment.encounter_datetime DESC
        LIMIT #{limit} OFFSET #{offset}
      SQL

      ActiveRecord::Base.connection.select_all(sql).to_a
    rescue StandardError => e
      Rails.logger.error("Error finding patients needing dispensation: #{e.message}")
      raise # Re-raise to expose database errors instead of hiding patients
    end

    def get_encounter_type_ids
      treatment_enc = EncounterType.find_by_name('TREATMENT')
      dispensing_enc = EncounterType.find_by_name('DISPENSING')
      
      {
        treatment: [treatment_enc&.encounter_type_id].compact,
        dispensing: [dispensing_enc&.encounter_type_id].compact
      }
    end

    def format_patient_data(patient)
      # Get patient program info
      program_info = get_patient_program_info(patient['patient_id'])
      
      {
        patient_id: patient['patient_id'],
        patientId: patient['national_id'] || "N/A",
        name: format_patient_name(patient['given_name'], patient['family_name']),
        genderAge: format_gender_age(patient['gender'], patient['birthdate'], patient['patient_id']),
        gender: patient['gender'],
        birthdate: patient['birthdate'],
        program: program_info[:program],
        treatment_datetime: patient['treatment_datetime'],
        visit_date: patient['visit_date']
      }
    end

    def get_patient_program_info(patient_id)
      # Simply use the program name from the initialized program
      { program: @program.name }
    rescue StandardError => e
      Rails.logger.error("Error getting program info for patient #{patient_id}: #{e.message}")
      { program: 'Unknown' }
    end

    def format_patient_name(given_name, family_name)
      name = "#{given_name} #{family_name}".strip
      name.empty? ? 'N/A' : name
    end

    def format_gender_age(gender, birthdate, patient_id)
      return "#{gender} / N/A" unless birthdate

      # Calculate age directly from birthdate using @date (selected batch date)
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
  end
end
