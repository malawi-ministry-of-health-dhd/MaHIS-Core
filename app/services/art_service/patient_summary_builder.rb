# frozen_string_literal: true

module ArtService
  # Builds a denormalized ART clinical summary for embedding in the patients_records
  # CouchDB document as the `art_summary` field. Used for offline-first ART workflows.
  class PatientSummaryBuilder
    HIV_PROGRAM_NAME  = 'HIV Program'
    ARV_NUMBER_TYPE   = 'ARV Number'

    WEIGHT_CONCEPT          = 'Weight (kg)'
    HEIGHT_CONCEPT          = 'Height (cm)'
    TB_STATUS_CONCEPT       = 'TB Status'
    PATIENT_TYPE_CONCEPT    = 'Type of patient'
    PATIENT_PRESENT_CONCEPT = 'Patient present'
    PREGNANT_CONCEPT        = 'Pregnancy status'
    BREASTFEEDING_CONCEPT   = 'Breast feeding'
    SIDE_EFFECTS_CONCEPT    = 'Malawi ART side effects'

    TPT_DRUG_CONCEPTS    = %w[Isoniazid Rifapentine Isoniazid/Rifapentine].freeze
    TPT_IPT_MONTHS       = 6
    TPT_3HP_MONTHS       = 3
    RECENT_VISITS_LIMIT  = 5

    # Encounter type names (exact DB strings — match workflow_engine.rb)
    HIV_CLINIC_REGISTRATION_ENCOUNTER = 'HIV CLINIC REGISTRATION'
    HIV_RECEPTION_ENCOUNTER           = 'HIV RECEPTION'
    VITALS_ENCOUNTER                  = 'VITALS'
    SYMPTOM_SCREENING_ENCOUNTER       = 'SYMPTOM SCREENING'
    HIV_STAGING_ENCOUNTER             = 'HIV STAGING'
    AHD_SCREENING_ENCOUNTER           = 'AHD SCREENING'
    ART_ADHERENCE_ENCOUNTER           = 'ART ADHERENCE'
    HIV_CLINIC_CONSULT_ENCOUNTER      = 'HIV CLINIC CONSULTATION'
    TREATMENT_ENCOUNTER               = 'TREATMENT'
    FAST_TRACK_ENCOUNTER              = 'FAST TRACK ASSESMENT' # intentional DB typo
    DISPENSING_ENCOUNTER              = 'DISPENSING'
    APPOINTMENT_ENCOUNTER             = 'APPOINTMENT'

    # Additional concept names
    REFER_TO_CLINICIAN_CONCEPT = 'Refer to ART clinician'
    APPOINTMENT_DATE_CONCEPT   = 'Appointment date'
    MEDICATION_ORDERS_CONCEPT  = 'Medication orders'

    # patient_state.state value for Died
    DIED_STATE = 3

    def initialize(patient_id, as_of: Date.today)
      @patient_id = patient_id.to_i
      @as_of      = as_of
    end

    def build
      preload_data

      {
        'art_start_date' => art_start_date,
        'arv_number' => arv_number,
        'init_pregnant' => init_pregnant?,
        'current_tb_status' => latest_obs_value(TB_STATUS_CONCEPT),
        'current_status_on_tb_treatment' => on_tb_treatment?,
        'current_patient_type' => latest_obs_value(PATIENT_TYPE_CONCEPT),
        'current_height' => latest_obs_numeric(HEIGHT_CONCEPT),
        'current_weight' => latest_obs_numeric(WEIGHT_CONCEPT),
        'current_outcome' => current_outcome,
        'current_regimen' => current_regimen,
        'tpt_completed' => tpt_completed?,
        'tpt_start_date' => tpt_start_date,
        'tpt_regimen' => tpt_regimen,
        'hiv_clinic_encounter' => hiv_clinic_encounter?,
        'is_alive' => is_alive?,
        'has_height_ever' => has_height_ever?,
        'ever_received_arvs' => ever_received_arvs?,
        'already_staged' => already_staged?,
        'visits' => build_visits
      }
    end

    private

    # ── Preloading ───────────────────────────────────────────────────────────

    def preload_data
      @concept_id_map = fetch_concept_ids(
        [WEIGHT_CONCEPT, HEIGHT_CONCEPT, TB_STATUS_CONCEPT, PATIENT_TYPE_CONCEPT,
         PATIENT_PRESENT_CONCEPT, PREGNANT_CONCEPT, BREASTFEEDING_CONCEPT, SIDE_EFFECTS_CONCEPT,
         REFER_TO_CLINICIAN_CONCEPT, APPOINTMENT_DATE_CONCEPT, MEDICATION_ORDERS_CONCEPT]
      )
      @tpt_drug_concept_ids = fetch_concept_ids(TPT_DRUG_CONCEPTS).values

      arv_concept_id = ConceptName.find_by(name: 'Antiretroviral drugs')&.concept_id
      @arv_drug_ids = if arv_concept_id
                        ConceptSet.where(concept_set: arv_concept_id)
                                  .pluck(:concept_id)
                                  .then { |ids| Drug.where(concept_id: ids).pluck(:drug_id) }
                      else
                        []
                      end
      @tpt_drug_ids = Drug.where(concept_id: @tpt_drug_concept_ids).pluck(:drug_id)

      @all_obs                = load_all_obs
      @all_orders             = load_all_orders
      @visit_dates            = load_visit_dates
      @all_encounters_by_date = load_all_encounters
      @clinician_obs_dates    = load_clinician_obs_dates
    end

    def fetch_concept_ids(names)
      ConceptName.where(name: names)
                 .pluck(:name, :concept_id)
                 .each_with_object({}) { |(name, id), h| h[name] ||= id }
    end

    def load_all_obs
      return {} if @concept_id_map.empty?

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT o.concept_id,
               DATE(o.obs_datetime)  AS obs_date,
               o.value_text,
               o.value_numeric,
               o.value_datetime,
               cn.name               AS value_coded_name
        FROM obs o
        LEFT JOIN concept_name cn ON cn.concept_id = o.value_coded AND cn.voided = 0
        WHERE o.person_id = #{@patient_id}
          AND o.voided    = 0
          AND o.concept_id IN (#{@concept_id_map.values.join(',')})
        ORDER BY o.obs_datetime DESC
      SQL

      rows.group_by { |r| r['concept_id'] }
    end

    def load_all_orders
      all_drug_ids = (@arv_drug_ids + @tpt_drug_ids).uniq
      return {} if all_drug_ids.empty?

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DATE(o.start_date)        AS order_date,
               d.name                   AS drug_name,
               do_tbl.drug_inventory_id,
               do_tbl.quantity
        FROM orders o
        INNER JOIN drug_order do_tbl ON do_tbl.order_id = o.order_id AND do_tbl.quantity > 0
        INNER JOIN drug d            ON d.drug_id = do_tbl.drug_inventory_id
        WHERE o.patient_id = #{@patient_id}
          AND o.voided     = 0
          AND do_tbl.drug_inventory_id IN (#{all_drug_ids.join(',')})
        ORDER BY o.start_date DESC
      SQL

      rows.group_by { |r| r['order_date']&.to_s }
    end

    def load_visit_dates
      ActiveRecord::Base.connection.exec_query(<<~SQL).map { |r| r['visit_date'] }
        SELECT DISTINCT DATE(encounter_datetime) AS visit_date
        FROM encounter
        WHERE patient_id = #{@patient_id}
          AND voided     = 0
          AND program_id = #{hiv_program_id}
        ORDER BY visit_date DESC
        LIMIT #{RECENT_VISITS_LIMIT}
      SQL
    end

    def load_all_encounters
      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DATE(e.encounter_datetime) AS enc_date,
               et.name                   AS enc_type
        FROM encounter e
        INNER JOIN encounter_type et ON et.encounter_type_id = e.encounter_type
        WHERE e.patient_id = #{@patient_id}
          AND e.voided     = 0
          AND e.program_id = #{hiv_program_id}
        ORDER BY e.encounter_datetime DESC
      SQL

      rows.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |r, h|
        h[r['enc_date'].to_s].add(r['enc_type'].upcase)
      end
    end

    def load_clinician_obs_dates
      med_orders_concept_id = @concept_id_map[MEDICATION_ORDERS_CONCEPT]
      return Set.new unless med_orders_concept_id

      clinician_user_ids = User.joins(:roles)
                               .where(user_role: { role: 'Clinician' })
                               .pluck(:user_id)
      return Set.new if clinician_user_ids.empty?

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DISTINCT DATE(o.obs_datetime) AS obs_date
        FROM obs o
        INNER JOIN encounter e ON e.encounter_id = o.encounter_id
        WHERE o.person_id  = #{@patient_id}
          AND o.voided     = 0
          AND o.concept_id = #{med_orders_concept_id}
          AND o.creator    IN (#{clinician_user_ids.join(',')})
          AND e.program_id = #{hiv_program_id}
      SQL

      Set.new(rows.map { |r| r['obs_date'].to_s })
    end

    # ── Enrollment / static ──────────────────────────────────────────────────

    def arv_number
      PatientIdentifier
        .joins(:type)
        .where(patient_id: @patient_id,
               patient_identifier_type: { name: ARV_NUMBER_TYPE },
               voided: 0)
        .order(date_created: :desc)
        .pick(:identifier)
    end

    def art_start_date
      row = ActiveRecord::Base.connection.select_one(<<~SQL)
        SELECT date_antiretrovirals_started(#{@patient_id}, MIN(s.start_date)) AS start_date
        FROM patient_program p
        INNER JOIN patient_state s ON s.patient_program_id = p.patient_program_id AND s.voided = 0
        WHERE p.patient_id  = #{@patient_id}
          AND p.program_id  = #{hiv_program_id}
          AND p.voided      = 0
          AND s.state       = #{on_arvs_state_id}
      SQL
      row&.dig('start_date')&.to_s.presence
    end

    def init_pregnant?
      rows = @all_obs[@concept_id_map[PREGNANT_CONCEPT]] || []
      first_obs = rows.min_by { |r| r['obs_date'] }
      return false unless first_obs

      truthy_value?(first_obs)
    end

    # ── Current clinical state ───────────────────────────────────────────────

    def current_outcome
      row = ActiveRecord::Base.connection.select_one(
        "SELECT patient_outcome(#{@patient_id}, '#{@as_of.strftime('%Y-%m-%d 23:59:59')}') AS outcome"
      )
      row&.dig('outcome')
    end

    def current_regimen
      row = ActiveRecord::Base.connection.select_one(
        "SELECT patient_current_regimen(#{@patient_id}, '#{@as_of.strftime('%Y-%m-%d 23:59:59')}') AS regimen"
      )
      row&.dig('regimen').presence
    end

    def latest_obs_value(concept_name)
      concept_id = @concept_id_map[concept_name]
      return nil unless concept_id

      first = (@all_obs[concept_id] || []).first
      return nil unless first

      first['value_coded_name'] || first['value_text'].presence
    end

    def latest_obs_numeric(concept_name)
      concept_id = @concept_id_map[concept_name]
      return nil unless concept_id

      (@all_obs[concept_id] || []).first&.dig('value_numeric')
    end

    def on_tb_treatment?
      latest_obs_value(TB_STATUS_CONCEPT)&.match?(/rx/i) || false
    end

    # ── Global patient flags ─────────────────────────────────────────────────

    def hiv_clinic_encounter?
      @all_encounters_by_date.values.any? { |types| types.include?(HIV_CLINIC_CONSULT_ENCOUNTER) }
    end

    def is_alive?
      program = PatientProgram.find_by(patient_id: @patient_id, program_id: hiv_program_id)
      return true if program.nil?

      !PatientState.where(patient_program_id: program.patient_program_id, state: DIED_STATE)
                   .where('start_date <= ?', @as_of)
                   .exists?
    end

    def has_height_ever?
      (@all_obs[@concept_id_map[HEIGHT_CONCEPT]] || []).any?
    end

    def ever_received_arvs?
      @all_orders.values.flatten.any? { |r| @arv_drug_ids.include?(r['drug_inventory_id']) }
    end

    def already_staged?
      @all_encounters_by_date.values.any? { |types| types.include?(HIV_STAGING_ENCOUNTER) }
    end

    # ── Per-visit helpers ────────────────────────────────────────────────────

    def encounter_done_on?(date_str, enc_type_name)
      (@all_encounters_by_date[date_str] || Set.new).include?(enc_type_name)
    end

    def referred_to_clinician_on?(obs_on_date)
      obs_value_on(obs_on_date, REFER_TO_CLINICIAN_CONCEPT)&.match?(/yes|true|1/i) || false
    end

    def appointment_date_on(obs_on_date)
      concept_id = @concept_id_map[APPOINTMENT_DATE_CONCEPT]
      return nil unless concept_id

      obs_on_date[concept_id]&.dig('value_datetime')&.to_s&.then { |v| v.empty? ? nil : v.split(' ').first }
    end

    def has_received_arvs_before?(date_str)
      @all_orders.any? do |order_date, rows|
        order_date < date_str && rows.any? { |r| @arv_drug_ids.include?(r['drug_inventory_id']) }
      end
    end

    # ── TPT ──────────────────────────────────────────────────────────────────

    def tpt_orders
      @tpt_orders ||= @all_orders.values.flatten
                                 .select { |r| @tpt_drug_ids.include?(r['drug_inventory_id']) }
                                 .sort_by { |r| r['order_date'] }
    end

    def tpt_start_date
      tpt_orders.first&.dig('order_date')&.to_s.presence
    end

    def tpt_regimen
      tpt_orders.first&.dig('drug_name').presence
    end

    def tpt_completed?
      return false if tpt_orders.empty?

      dispensation_dates = tpt_orders.map { |r| r['order_date'] }.uniq
      is_3hp = tpt_orders.any? { |r| r['drug_name']&.match?(/rifapentine/i) }
      threshold = is_3hp ? TPT_3HP_MONTHS : TPT_IPT_MONTHS
      dispensation_dates.size >= threshold
    end

    # ── Per-visit map ────────────────────────────────────────────────────────

    def build_visits
      @visit_dates.each_with_object({}) do |date, visits|
        date_str = date.to_s
        visits[date_str] = build_visit(date_str)
      end
    end

    def build_visit(date_str)
      obs_on_date    = obs_for_date(date_str)
      orders_on_date = @all_orders[date_str] || []

      arv_drugs   = orders_on_date.select { |r| @arv_drug_ids.include?(r['drug_inventory_id']) }
                                  .uniq { |r| r['drug_name'] }
                                  .map { |r| { 'name' => r['drug_name'], 'quantity' => r['quantity'] } }
      other_drugs = orders_on_date.select { |r| @tpt_drug_ids.include?(r['drug_inventory_id']) }
                                  .map { |r| r['drug_name'] }.uniq

      outcome_row = ActiveRecord::Base.connection.select_one(
        "SELECT patient_outcome(#{@patient_id}, '#{date_str} 23:59:59') AS outcome"
      )

      {
        'weight'                    => obs_numeric_on(obs_on_date, WEIGHT_CONCEPT),
        'height'                    => obs_numeric_on(obs_on_date, HEIGHT_CONCEPT),
        'outcome'                   => outcome_row&.dig('outcome'),
        'drugs'                     => arv_drugs,
        'tb_status'                 => obs_value_on(obs_on_date, TB_STATUS_CONCEPT),
        'tb_treatment_status'       => obs_value_on(obs_on_date, TB_STATUS_CONCEPT)&.match?(/rx/i) || false,
        'patient_type'              => obs_value_on(obs_on_date, PATIENT_TYPE_CONCEPT),
        'patient_present'           => truthy_value_in?(obs_on_date, PATIENT_PRESENT_CONCEPT),
        'guardian_present'          => guardian_present_on?(obs_on_date),
        'pregnant'                  => truthy_value_in?(obs_on_date, PREGNANT_CONCEPT),
        'breastfeeding'             => truthy_value_in?(obs_on_date, BREASTFEEDING_CONCEPT),
        'side_effects'              => obs_value_on(obs_on_date, SIDE_EFFECTS_CONCEPT),
        'other_drugs'               => other_drugs.join(', ').presence,
        'has_reception'             => encounter_done_on?(date_str, HIV_RECEPTION_ENCOUNTER),
        'has_received_arvs_before'  => has_received_arvs_before?(date_str),
        'referred_to_clinician'     => referred_to_clinician_on?(obs_on_date),
        'seen_by_clinician'         => @clinician_obs_dates.include?(date_str),
        'has_treatment_encounter'   => encounter_done_on?(date_str, TREATMENT_ENCOUNTER),
        'next_appointment_date'     => appointment_date_on(obs_on_date),
        'hasHivClinicRegistration'  => encounter_done_on?(date_str, HIV_CLINIC_REGISTRATION_ENCOUNTER),
        'hasHivReception'           => encounter_done_on?(date_str, HIV_RECEPTION_ENCOUNTER),
        'hasVitals'                 => encounter_done_on?(date_str, VITALS_ENCOUNTER),
        'hasSymptomScreening'       => encounter_done_on?(date_str, SYMPTOM_SCREENING_ENCOUNTER),
        'hasHivStaging'             => encounter_done_on?(date_str, HIV_STAGING_ENCOUNTER),
        'hasAhdScreening'           => encounter_done_on?(date_str, AHD_SCREENING_ENCOUNTER),
        'hasArtAdherence'           => encounter_done_on?(date_str, ART_ADHERENCE_ENCOUNTER),
        'hasHivClinicConsultation'  => encounter_done_on?(date_str, HIV_CLINIC_CONSULT_ENCOUNTER),
        'hasTreatment'              => encounter_done_on?(date_str, TREATMENT_ENCOUNTER),
        'hasFastTrackAssessment'    => encounter_done_on?(date_str, FAST_TRACK_ENCOUNTER),
        'hasDispensing'             => encounter_done_on?(date_str, DISPENSING_ENCOUNTER),
        'hasAppointment'            => encounter_done_on?(date_str, APPOINTMENT_ENCOUNTER)
      }
    end

    def obs_for_date(date_str)
      @concept_id_map.each_with_object({}) do |(_name, concept_id), h|
        rows = @all_obs[concept_id] || []
        h[concept_id] = rows.find { |r| r['obs_date'].to_s == date_str }
      end
    end

    def obs_value_on(obs_on_date, concept_name)
      concept_id = @concept_id_map[concept_name]
      return nil unless concept_id

      row = obs_on_date[concept_id]
      row&.dig('value_coded_name') || row&.dig('value_text').presence
    end

    def obs_numeric_on(obs_on_date, concept_name)
      concept_id = @concept_id_map[concept_name]
      return nil unless concept_id

      obs_on_date[concept_id]&.dig('value_numeric')
    end

    def truthy_value_in?(obs_on_date, concept_name)
      obs_value_on(obs_on_date, concept_name)&.match?(/yes|true|1/i) || false
    end

    def guardian_present_on?(obs_on_date)
      obs_value_on(obs_on_date, PATIENT_PRESENT_CONCEPT)&.match?(/guardian/i) || false
    end

    def truthy_value?(row)
      val = row['value_coded_name'] || row['value_text'] || ''
      val.match?(/yes|true|1/i)
    end

    # ── Cached IDs ───────────────────────────────────────────────────────────

    def hiv_program_id
      @hiv_program_id ||= Program.find_by_name(HIV_PROGRAM_NAME)&.program_id
    end

    def on_arvs_state_id
      @on_arvs_state_id ||= Program.find_by_name(HIV_PROGRAM_NAME)
                                   &.state('On antiretrovirals')
                                   &.program_workflow_state_id
    end
  end
end
