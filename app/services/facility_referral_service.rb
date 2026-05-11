# frozen_string_literal: true

class FacilityReferralService
  REFERRAL_ENCOUNTER_TYPE_ID = 103
  DEPARTMENT_CONCEPT_ID = 50_615
  REFERRAL_FACILITY_CONCEPT_ID = 49_528
  PRIMARY_REFERRAL_CONCEPT_IDS = [DEPARTMENT_CONCEPT_ID, REFERRAL_FACILITY_CONCEPT_ID].freeze
  PROGRAM_DEPARTMENT_NAMES = {
    19 => 'ANC Connect',
    36 => 'Labour and Delivery'
  }.freeze

  def index(filters)
    referrals = referral_rows(filters)
    return [] if referrals.blank?

    details_by_encounter = other_details_by_encounter(referrals.pluck('encounter_id'))

    referrals.each do |referral|
      referral['other_details'] = details_by_encounter.fetch(referral['encounter_id'], [])
    end
  end

  private

  def referral_rows(filters)
    sql = sanitize_sql([base_referral_sql(filters), bind_values(filters)])

    ActiveRecord::Base.connection.select_all(sql).to_a.map do |row|
      normalize_referral_row(row)
    end
  end

  def base_referral_sql(filters)
    <<~SQL.squish
      SELECT
        e.encounter_id,
        e.patient_id,
        patient_name.given_name AS first_name,
        patient_name.family_name AS last_name,
        e.encounter_datetime,
        e.location_id,
        source_location.name AS referred_from,
        e.program_id AS encounter_program_id,
        source_program.name AS source_program,
        department_obs.obs_id AS department_obs_id,
        COALESCE(department_program_numeric.program_id,
                 department_program_coded.program_id,
                 department_program_text.program_id,
                 CAST(department_obs.value_numeric AS UNSIGNED)) AS referred_program_id,
        COALESCE(department_program_numeric.name,
                 department_program_coded.name,
                 department_program_text.name,
                 department_answer_name.name,
                 department_obs.value_text,
                 CAST(department_obs.value_numeric AS CHAR)) AS referred_program_name,
        COALESCE(department_program_numeric.name,
                 department_program_coded.name,
                 department_program_text.name,
                 department_answer_name.name,
                 department_obs.value_text,
                 CAST(department_obs.value_numeric AS CHAR)) AS referred_department,
        department_obs.value_coded AS referred_program_coded,
        referral_facility_obs.obs_id AS referral_facility_obs_id,
        COALESCE(referral_facility_numeric.location_id,
                 referral_facility_coded.location_id,
                 referral_facility_text.location_id,
                 CAST(referral_facility_obs.value_numeric AS UNSIGNED),
                 referral_facility_obs.value_coded) AS referred_facility_id,
        COALESCE(referral_facility_numeric.name,
                 referral_facility_coded.name,
                 referral_facility_text.name,
                 referral_facility_answer_name.name,
                 referral_facility_obs.value_text,
                 CAST(referral_facility_obs.value_numeric AS CHAR),
                 CAST(referral_facility_obs.value_coded AS CHAR)) AS referred_facility,
        referral_facility_obs.value_coded AS referred_facility_coded
      FROM encounter e
      INNER JOIN obs department_obs
        ON department_obs.encounter_id = e.encounter_id
       AND department_obs.voided = 0
       AND department_obs.concept_id = :department_concept_id
      INNER JOIN obs referral_facility_obs
        ON referral_facility_obs.encounter_id = e.encounter_id
       AND referral_facility_obs.voided = 0
       AND referral_facility_obs.concept_id = :referral_facility_concept_id
      LEFT JOIN person_name patient_name
        ON patient_name.person_name_id = (
          SELECT latest_name.person_name_id
          FROM person_name latest_name
          WHERE latest_name.person_id = e.patient_id
            AND latest_name.voided = 0
          ORDER BY latest_name.preferred DESC,
                   latest_name.date_created DESC,
                   latest_name.person_name_id DESC
          LIMIT 1
        )
      LEFT JOIN location source_location
        ON source_location.location_id = e.location_id
      LEFT JOIN program source_program
        ON source_program.program_id = e.program_id
      LEFT JOIN program department_program_numeric
        ON department_program_numeric.program_id = CAST(department_obs.value_numeric AS UNSIGNED)
      LEFT JOIN program department_program_coded
        ON department_program_coded.program_id = department_obs.value_coded
      LEFT JOIN program department_program_text
        ON department_program_text.name = department_obs.value_text
      LEFT JOIN concept_name department_answer_name
        ON department_answer_name.concept_name_id = (
          SELECT concept_name.concept_name_id
          FROM concept_name
          WHERE concept_name.concept_id = department_obs.value_coded
            AND concept_name.voided = 0
          ORDER BY concept_name.locale_preferred DESC,
                   concept_name.concept_name_id ASC
          LIMIT 1
        )
      LEFT JOIN location referral_facility_numeric
        ON referral_facility_numeric.location_id = CAST(referral_facility_obs.value_numeric AS UNSIGNED)
      LEFT JOIN location referral_facility_coded
        ON referral_facility_coded.location_id = referral_facility_obs.value_coded
      LEFT JOIN location referral_facility_text
        ON referral_facility_text.name = referral_facility_obs.value_text
      LEFT JOIN concept_name referral_facility_answer_name
        ON referral_facility_answer_name.concept_name_id = (
          SELECT concept_name.concept_name_id
          FROM concept_name
          WHERE concept_name.concept_id = referral_facility_obs.value_coded
            AND concept_name.voided = 0
          ORDER BY concept_name.locale_preferred DESC,
                   concept_name.concept_name_id ASC
          LIMIT 1
        )
      WHERE #{where_clause(filters)}
      ORDER BY e.encounter_datetime DESC, e.encounter_id DESC
    SQL
  end

  def where_clause(filters)
    clauses = [
      'e.voided = 0',
      'e.encounter_type = :referral_encounter_type_id'
    ]

    clauses << 'e.patient_id = :patient_id' if normalized_filter(filters[:patient_id]).present?
    clauses << program_filter_clause(filters[:program_id]) if normalized_filter(filters[:program_id]).present?
    clauses << facility_filter_clause(facility_filter(filters)) if facility_filter(filters).present?
    clauses << 'e.encounter_datetime >= :date_from' if normalized_filter(filters[:date_from]).present?
    clauses << 'e.encounter_datetime <= :date_to' if normalized_filter(filters[:date_to]).present?

    clauses.compact.join(' AND ')
  end

  def program_filter_clause(program)
    program_ids = program_ids_for(program)
    program_values = program_values_for(program)
    clauses = []
    clauses << 'department_obs.value_numeric IN (:program_ids)' if program_ids.any?
    clauses << 'department_obs.value_coded IN (:program_ids)' if program_ids.any?
    clauses << 'department_obs.value_text IN (:program_values)' if program_values.any?

    "(#{clauses.join(' OR ')})"
  end

  def facility_filter_clause(facility)
    facility_ids = facility_ids_for(facility)
    facility_values = facility_values_for(facility)
    clauses = []
    clauses << 'referral_facility_obs.value_numeric IN (:facility_ids)' if facility_ids.any?
    clauses << 'referral_facility_obs.value_coded IN (:facility_ids)' if facility_ids.any?
    clauses << 'referral_facility_obs.value_text IN (:facility_values)' if facility_values.any?

    "(#{clauses.join(' OR ')})"
  end

  def bind_values(filters)
    values = {
      referral_encounter_type_id: REFERRAL_ENCOUNTER_TYPE_ID,
      department_concept_id: DEPARTMENT_CONCEPT_ID,
      referral_facility_concept_id: REFERRAL_FACILITY_CONCEPT_ID
    }

    patient_id = normalized_filter(filters[:patient_id])
    program = normalized_filter(filters[:program_id])
    facility = facility_filter(filters)
    date_from = normalized_filter(filters[:date_from])
    date_to = normalized_filter(filters[:date_to])

    values[:patient_id] = patient_id if patient_id.present?
    values[:program_ids] = program_ids_for(program) if program.present? && program_ids_for(program).any?
    values[:program_values] = program_values_for(program) if program.present? && program_values_for(program).any?
    values[:facility_ids] = facility_ids_for(facility) if facility.present? && facility_ids_for(facility).any?
    values[:facility_values] = facility_values_for(facility) if facility.present? && facility_values_for(facility).any?
    values[:date_from] = TimeUtils.day_bounds(date_from).first if date_from.present?
    values[:date_to] = TimeUtils.day_bounds(date_to).last if date_to.present?

    values
  end

  def other_details_by_encounter(encounter_ids)
    return {} if encounter_ids.blank?

    sql = sanitize_sql([
      other_details_sql,
      encounter_ids: encounter_ids.map(&:to_i),
      primary_referral_concept_ids: PRIMARY_REFERRAL_CONCEPT_IDS
    ])

    ActiveRecord::Base.connection.select_all(sql).to_a.each_with_object({}) do |row, details|
      row = normalize_detail_row(row)
      details[row['encounter_id']] ||= []
      details[row['encounter_id']] << row
    end
  end

  def other_details_sql
    <<~SQL.squish
      SELECT
        obs.encounter_id,
        obs.obs_id,
        observation_concept_name.name AS concept_name,
        CASE
          WHEN obs.value_coded IS NOT NULL THEN COALESCE(answer_concept_name.name, CAST(obs.value_coded AS CHAR))
          WHEN obs.value_text IS NOT NULL THEN obs.value_text
          WHEN obs.value_numeric IS NOT NULL THEN CAST(obs.value_numeric AS CHAR)
          WHEN obs.value_datetime IS NOT NULL THEN DATE_FORMAT(obs.value_datetime, '%Y-%m-%d %H:%i:%s')
          WHEN obs.value_boolean IS NOT NULL THEN IF(obs.value_boolean = 1, 'Yes', 'No')
          ELSE NULL
        END AS value
      FROM obs
      LEFT JOIN concept_name observation_concept_name
        ON observation_concept_name.concept_name_id = (
          SELECT concept_name.concept_name_id
          FROM concept_name
          WHERE concept_name.concept_id = obs.concept_id
            AND concept_name.voided = 0
          ORDER BY concept_name.locale_preferred DESC,
                   concept_name.concept_name_id ASC
          LIMIT 1
        )
      LEFT JOIN concept_name answer_concept_name
        ON answer_concept_name.concept_name_id = (
          SELECT concept_name.concept_name_id
          FROM concept_name
          WHERE concept_name.concept_id = obs.value_coded
            AND concept_name.voided = 0
          ORDER BY concept_name.locale_preferred DESC,
                   concept_name.concept_name_id ASC
          LIMIT 1
        )
      WHERE obs.voided = 0
        AND obs.encounter_id IN (:encounter_ids)
        AND obs.concept_id NOT IN (:primary_referral_concept_ids)
      ORDER BY obs.encounter_id, obs.obs_id
    SQL
  end

  def normalize_referral_row(row)
    integer_columns = %w[
      encounter_id patient_id encounter_program_id department_obs_id
      referred_program_id referred_program_coded referral_facility_obs_id
      referred_facility_id referred_facility_coded
    ]

    integer_columns.each { |column| row[column] = integer_value(row[column]) }
    row
  end

  def normalize_detail_row(row)
    row['encounter_id'] = integer_value(row['encounter_id'])
    row['obs_id'] = integer_value(row['obs_id'])
    row['value'] = normalized_numeric_string(row['value'])
    row
  end

  def program_ids_for(program)
    @program_ids_for ||= {}
    program = normalized_filter(program)

    @program_ids_for[program] ||= begin
      ids = []
      ids << program.to_i if numeric?(program)
      ids.concat(Program.unscoped.where(name: program).pluck(:program_id))
      ids.compact.uniq
    end
  end

  def program_values_for(program)
    @program_values_for ||= {}
    program = normalized_filter(program)

    @program_values_for[program] ||= begin
      values = [program]
      program_id = numeric?(program) ? program.to_i : nil
      values << PROGRAM_DEPARTMENT_NAMES[program_id] if program_id
      values.concat(Program.unscoped.where(program_id: program_id).pluck(:name)) if program_id
      values.compact.uniq
    end
  end

  def facility_ids_for(facility)
    @facility_ids_for ||= {}
    facility = normalized_filter(facility)

    @facility_ids_for[facility] ||= begin
      ids = []
      ids << facility.to_i if numeric?(facility)
      ids.concat(Location.unscoped.where(name: facility).pluck(:location_id))
      ids.compact.uniq
    end
  end

  def facility_values_for(facility)
    @facility_values_for ||= {}
    facility = normalized_filter(facility)

    @facility_values_for[facility] ||= begin
      values = [facility]
      facility_id = numeric?(facility) ? facility.to_i : nil
      values.concat(Location.unscoped.where(location_id: facility_id).pluck(:name)) if facility_id
      values.compact.uniq
    end
  end

  def facility_filter(filters)
    normalized_filter(filters[:facility]).presence || normalized_filter(filters[:location_id])
  end

  def normalized_filter(value)
    value.to_s.strip.gsub(/\A['"]+|['"]+\z/, '')
  end

  def integer_value(value)
    return nil if value.blank?

    value.to_i
  end

  def normalized_numeric_string(value)
    value.to_s.match?(/\A-?\d+\.0\z/) ? value.to_i.to_s : value
  end

  def numeric?(value)
    value.to_s.match?(/\A\d+\z/)
  end

  def sanitize_sql(statement)
    ActiveRecord::Base.send(:sanitize_sql_array, statement)
  end
end
