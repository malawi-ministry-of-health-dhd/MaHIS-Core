class NruService
  NRU_OUTCOME_ENCOUNTER_TYPE = 93   # DISCHARGE_DIAGNOSIS — where Outcome obs are saved
  NRU_ANTHROPOMETRY_ENCOUNTER_TYPE = 6  # VITALS — where "Days in NRU" (LOS) obs are saved
  NRU_MANAGEMENT_ENCOUNTER_TYPE = 22

  def initialize(program_id:)
    @program_id = program_id.to_i
  end

  def dashboard(date: Date.today)
    month_start = date.beginning_of_month.to_date
    month_end   = date.end_of_month.to_date

    active_ids     = active_admitted_patient_ids
    stab_count     = count_patients_by_feed(active_ids, 'F-75')
    trans_count    = count_patients_by_feed(active_ids, 'F-100', 'RUTF')
    monthly        = monthly_outcomes_data(month_start, month_end)
    total_disc     = monthly.values.sum
    cured_count    = monthly['Cured'].to_i
    cure_rate_pct  = total_disc.positive? ? (cured_count.to_f / total_disc * 100).round : 0
    avg            = average_los(month_start, month_end)

    {
      active_admissions: active_ids.size,
      stabilisation:     stab_count,
      transition:        trans_count,
      cured_this_month:  cured_count,
      avg_los:           avg,
      cure_rate:         cure_rate_pct,
      outcomes: {
        cured:            { count: monthly['Cured'].to_i,            pct: pct(monthly['Cured'],            total_disc) },
        defaulted:        { count: monthly['Early Departed'].to_i,   pct: pct(monthly['Early Departed'],   total_disc) },
        non_cured:        { count: monthly['Non-cured'].to_i,        pct: pct(monthly['Non-cured'],        total_disc) },
        died:             { count: monthly['Died'].to_i,             pct: pct(monthly['Died'],             total_disc) },
        medical_transfer: { count: (monthly['Medical Transfer'].to_i + monthly['Transferred'].to_i),
                            pct:   pct(monthly['Medical Transfer'].to_i + monthly['Transferred'].to_i, total_disc) }
      }
    }
  end

  private

  def active_admitted_patient_ids
    admitted_state = ProgramWorkflowState.find_by_name_and_program(name: 'Admitted', program_id: @program_id)
    return [] unless admitted_state

    PatientProgram.joins(:patient_states)
                  .where(program_id: @program_id, voided: 0)
                  .where("patient_state.state = ? AND patient_state.end_date IS NULL AND patient_state.voided = 0",
                         admitted_state.id)
                  .distinct
                  .pluck(:patient_id)
  end

  def count_patients_by_feed(patient_ids, *terms)
    return 0 if patient_ids.empty?

    feed_concept_id = ConceptName.where(name: 'Type of feed', voided: 0).pick(:concept_id)
    return 0 unless feed_concept_id

    like_clauses = terms.map { "cn.name LIKE ?" }.join(' OR ')
    params       = terms.map { |t| "%#{t}%" }

    Observation.joins("INNER JOIN concept_name cn ON cn.concept_id = obs.value_coded AND cn.voided = 0")
               .where("obs.person_id IN (?) AND obs.concept_id = ? AND obs.voided = 0", patient_ids, feed_concept_id)
               .where(like_clauses, *params)
               .distinct
               .count(:person_id)
  end

  def monthly_outcomes_data(start_date, end_date)
    outcome_concept_id = ConceptName.where(name: 'Outcome', voided: 0).pick(:concept_id)
    return {} unless outcome_concept_id

    # Subquery: for each patient get the obs_id of their LATEST outcome in the date range.
    # This ensures a patient counted only once even if multiple outcome records exist.
    latest_per_patient = Observation
      .joins("INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.voided = 0")
      .where("obs.concept_id = ? AND obs.voided = 0 AND e.encounter_type = ? AND e.program_id = ?",
             outcome_concept_id, NRU_OUTCOME_ENCOUNTER_TYPE, @program_id)
      .where("DATE(obs.obs_datetime) BETWEEN ? AND ?", start_date, end_date)
      .select("MAX(obs.obs_id) AS max_obs_id")
      .group("obs.person_id")

    Observation
      .joins("INNER JOIN (#{latest_per_patient.to_sql}) latest ON latest.max_obs_id = obs.obs_id")
      .where(voided: 0)
      .group(:value_text)
      .count
  end

  def average_los(start_date, end_date)
    los_concept_id = ConceptName.where(name: 'Days in NRU', voided: 0).pick(:concept_id)
    return 0 unless los_concept_id

    avg = Observation
            .joins("INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.voided = 0")
            .where("obs.concept_id = ? AND obs.voided = 0 AND e.encounter_type = ? AND e.program_id = ?",
                   los_concept_id, NRU_ANTHROPOMETRY_ENCOUNTER_TYPE, @program_id)
            .where("DATE(obs.obs_datetime) BETWEEN ? AND ?", start_date, end_date)
            .average(:value_numeric)
    avg ? avg.round : 0
  end

  def pct(value, total)
    return 0 if total.zero? || value.nil?
    (value.to_f / total * 100).round
  end
end