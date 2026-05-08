# frozen_string_literal: true

class FacilityReferralService
  REFERRAL_ENCOUNTER_TYPE_ID = 103
  DEPARTMENT_CONCEPTS = ['Department', 'program id'].freeze
  REFERRAL_FACILITY_CONCEPTS = ['Referral facility', 'facility to'].freeze
  PROGRAM_DEPARTMENT_NAMES = {
    19 => 'ANC Connect',
    36 => 'Labour and Delivery'
  }.freeze

  def index(filters)
    referrals = facility_referrals(filters)

    {
      data: referrals,
      count: referrals.length,
      total_count: referrals.length,
      filters: filters.to_h
    }
  end

  private

  def facility_referrals(filters)
    query = base_referrals_query
    return [] if query.blank?

    query = filter_by_program(query, filters[:program_id])
    query = filter_by_location(query, filters[:location_id])
    query = filter_by_date_from(query, filters[:date_from])
    query = filter_by_date_to(query, filters[:date_to])

    ActiveRecord::Base.connection.select_all(query.to_sql).to_a
  end

  def base_referrals_query
    department_concept_ids = concept_ids(DEPARTMENT_CONCEPTS)
    referral_facility_concept_ids = concept_ids(REFERRAL_FACILITY_CONCEPTS)

    return if [department_concept_ids, referral_facility_concept_ids].any?(&:blank?)

    Encounter
      .joins(department_observation_join(department_concept_ids))
      .joins(referral_facility_observation_join(referral_facility_concept_ids))
      .joins(patient_name_join)
      .joins(source_location_join)
      .joins(source_program_join)
      .where(encounter: { encounter_type: REFERRAL_ENCOUNTER_TYPE_ID })
      .select(
        'encounter.encounter_id',
        'encounter.patient_id',
        'patient_name.given_name AS first_name',
        'patient_name.family_name AS last_name',
        'encounter.encounter_datetime',
        'encounter.location_id',
        'source_location.name AS referred_from',
        'encounter.program_id AS encounter_program_id',
        'source_program.name AS source_program',
        'department_obs.obs_id AS department_obs_id',
        'department_obs.value_numeric AS referred_program_id',
        'department_obs.value_text AS referred_department',
        'department_obs.value_coded AS referred_program_coded',
        'referral_facility_obs.obs_id AS referral_facility_obs_id',
        'referral_facility_obs.value_numeric AS referred_facility_id',
        'referral_facility_obs.value_text AS referred_facility',
        'referral_facility_obs.value_coded AS referred_facility_coded'
      )
  end

  def department_observation_join(concept_ids)
    <<~SQL.squish
      LEFT JOIN obs department_obs
        ON department_obs.encounter_id = encounter.encounter_id
       AND department_obs.voided = 0
       AND department_obs.concept_id IN (#{concept_ids.join(',')})
    SQL
  end

  def referral_facility_observation_join(concept_ids)
    <<~SQL.squish
      INNER JOIN obs referral_facility_obs
        ON referral_facility_obs.encounter_id = encounter.encounter_id
       AND referral_facility_obs.voided = 0
       AND referral_facility_obs.concept_id IN (#{concept_ids.join(',')})
    SQL
  end

  def patient_name_join
    <<~SQL.squish
      LEFT JOIN person_name patient_name
        ON patient_name.person_name_id = (
          SELECT latest_name.person_name_id
          FROM person_name latest_name
          WHERE latest_name.person_id = encounter.patient_id
            AND latest_name.voided = 0
          ORDER BY latest_name.date_created DESC, latest_name.person_name_id DESC
          LIMIT 1
        )
    SQL
  end

  def source_location_join
    <<~SQL.squish
      LEFT JOIN location source_location
        ON source_location.location_id = encounter.location_id
    SQL
  end

  def source_program_join
    <<~SQL.squish
      LEFT JOIN program source_program
        ON source_program.program_id = encounter.program_id
    SQL
  end

  def filter_by_program(query, program_id)
    return query if program_id.blank?

    query.where(
      'department_obs.value_numeric IN (:program_ids) OR '\
      'department_obs.value_coded IN (:program_ids) OR '\
      'department_obs.value_text IN (:department_values)',
      program_ids: program_ids_for(program_id),
      department_values: department_values_for(program_id)
    )
  end

  def filter_by_location(query, location_id)
    return query if location_id.blank?

    query.where(
      'referral_facility_obs.value_numeric IN (:location_ids) OR '\
      'referral_facility_obs.value_coded IN (:location_ids) OR '\
      'referral_facility_obs.value_text IN (:facility_values)',
      location_ids: location_ids_for(location_id),
      facility_values: facility_values_for(location_id)
    )
  end

  def filter_by_date_from(query, date_from)
    return query if date_from.blank?

    start_time, = TimeUtils.day_bounds(date_from)
    query.where('encounter.encounter_datetime >= ?', start_time)
  end

  def filter_by_date_to(query, date_to)
    return query if date_to.blank?

    _, end_time = TimeUtils.day_bounds(date_to)
    query.where('encounter.encounter_datetime <= ?', end_time)
  end

  def concept_id(name)
    ConceptName.find_by_name(name)&.concept_id
  end

  def concept_ids(names)
    ConceptName.where(name: names).pluck(:concept_id).uniq
  end

  def program_ids_for(program)
    values = []
    values << program.to_i if numeric?(program)
    program_record = Program.find_by(name: program.to_s)
    values << program_record&.program_id
    values.compact.uniq
  end

  def department_values_for(program)
    program_id = numeric?(program) ? program.to_i : nil
    values = [program.to_s]
    values << PROGRAM_DEPARTMENT_NAMES[program_id] if program_id
    values << Program.find_by(program_id: program_id)&.name if program_id
    values.compact.uniq
  end

  def location_ids_for(location)
    values = []
    values << location.to_i if numeric?(location)
    location_record = Location.find_by(name: location.to_s)
    values << location_record&.location_id
    values.compact.uniq
  end

  def facility_values_for(location)
    location_id = numeric?(location) ? location.to_i : nil
    values = [location.to_s]
    values << Location.find_by(location_id: location_id)&.name if location_id
    values.compact.uniq
  end

  def numeric?(value)
    value.to_s.match?(/\A\d+\z/)
  end
end
