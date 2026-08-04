# frozen_string_literal: true

module ImpowService
  # Service for managing batch anthropometry
  # Handles listing patients who have completed triage but not anthropometry
  class BatchAnthropometryEngine
    DEFAULT_PER_PAGE = 20
    MAX_PER_PAGE = 100

    def initialize(program:, date: Date.today, page: 1, per_page: DEFAULT_PER_PAGE)
      @program = program
      @date = date
      @page = [page.to_i, 1].max
      @per_page = [[per_page.to_i, MAX_PER_PAGE].min, 1].max
      @location_id = Location.current.location_id
    end

    # Get patients who have triage encounters but no anthropometry/vitals for today
    def fetch_patients_awaiting_anthropometry
      patients = find_patients_with_triage_no_vitals
      total_count = patients.size
      
      # Paginate
      offset = (@page - 1) * @per_page
      paginated_patients = patients.slice(offset, @per_page) || []
      
      formatted_patients = paginated_patients.map do |patient_data|
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

    def find_patients_with_triage_no_vitals
      # Find encounter types
      triage_enc = EncounterType.find_by_name('TRIAGE')
      vitals_enc = EncounterType.find_by_name('VITALS')
      anthropometry_enc = EncounterType.find_by_name('ANTHROPOMETRY')
      
      return [] unless triage_enc

      vitals_type_ids = [vitals_enc&.encounter_type_id, anthropometry_enc&.encounter_type_id].compact
      return [] if vitals_type_ids.empty?

      # Deduplicate by restricting each optional join to one row per patient
      sql = <<~SQL
        SELECT DISTINCT
          p.patient_id,
          pn.given_name,
          pn.family_name,
          per.gender,
          per.birthdate,
          pi.identifier AS national_id,
          triage.encounter_datetime AS triage_datetime
        FROM encounter triage
        INNER JOIN patient p ON p.patient_id = triage.patient_id
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
        WHERE triage.encounter_type = #{triage_enc.encounter_type_id}
          AND triage.program_id = #{@program.program_id}
          AND triage.location_id = #{@location_id}
          AND triage.voided = 0
          AND DATE(triage.encounter_datetime) = '#{@date}'
          AND NOT EXISTS (
            SELECT 1 FROM encounter vitals
            WHERE vitals.patient_id = p.patient_id
              AND vitals.program_id = #{@program.program_id}
              AND vitals.encounter_type IN (#{vitals_type_ids.join(',')})
              AND vitals.voided = 0
              AND DATE(vitals.encounter_datetime) = '#{@date}'
          )
        ORDER BY triage.encounter_datetime ASC
      SQL

      ActiveRecord::Base.connection.select_all(sql).to_a
    rescue StandardError => e
      Rails.logger.error("Error finding patients awaiting anthropometry: #{e.message}")
      []
    end

    def format_patient_data(patient)
      {
        patient_id: patient['patient_id'],
        patientId: patient['national_id'] || "N/A",
        name: format_patient_name(patient['given_name'], patient['family_name']),
        genderAge: format_gender_age(patient['gender'], patient['birthdate'], patient['patient_id']),
        gender: patient['gender'],
        birthdate: patient['birthdate'],
        triage_datetime: patient['triage_datetime']
      }
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
  end
end
