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

    HAS_TRANSFER_LETTER_CONCEPT     = 'Has transfer letter'
    DATE_ART_LAST_TAKEN_CONCEPT     = 'Date ART last taken'
    TB_TREATMENT_START_DATE_CONCEPT = 'TB treatment start date'
    PILLS_BROUGHT_CONCEPT           = 'Amount of drug brought to clinic'
    HIV_VIRAL_LOAD_CONCEPT          = 'HIV Viral Load'
    TEST_TYPE_CONCEPT               = 'Test type'
    LAB_TEST_RESULT_CONCEPT         = 'Lab test result'

    TPT_DRUG_CONCEPTS    = %w[Isoniazid Rifapentine Isoniazid/Rifapentine].freeze
    TPT_IPT_MONTHS       = 6
    TPT_3HP_MONTHS       = 3

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

    # WHO staging criteria (stored as value_coded under this question concept)
    WHO_STAGES_CRITERIA_CONCEPT = 'Who stages criteria present'

    PTB_WITHIN_2_YEARS_NAMES = [
      'Tuberculosis (PTB or EPTB) within the last 2 years',
      'Pulmonary tuberculosis within the last 2 years',
      'PTB last 2 years',
      'Ptb within the past two years',
      'TB in previous two years'
    ].freeze
    EPTB_NAMES          = ['Extrapulmonary tuberculosis (EPTB)', 'EPTB'].freeze
    PTB_CURRENT_NAMES   = ['Pulmonary tuberculosis (current)', 'Pulmonary TB (current)'].freeze
    KAPOSIS_NAMES       = ['Kaposis sarcoma', 'Kaposi sarcoma'].freeze
    # Registration / staging concepts (for missing root fields)
    CONFIRMATORY_HIV_TEST_DATE_CONCEPT     = 'Confirmatory HIV test date'
    CONFIRMATORY_HIV_TEST_LOCATION_CONCEPT = 'Confirmatory HIV test location'
    AGREES_TO_FOLLOWUP_CONCEPT             = 'Agrees to followup'
    REASON_FOR_ART_ELIGIBILITY_CONCEPT     = 'Reason for ART eligibility'
    WHO_STAGE_CRITERIA_CONCEPT             = 'Who stages criteria present'
    INIT_BREASTFEEDING_CONCEPT             = 'Is patient breast feeding'

    # Dispensing / adherence concepts (for missing visit fields)
    AMOUNT_DISPENSED_CONCEPT = 'Amount dispensed'
    ADHERENCE_CONCEPT        = 'Drug Order Adherence'
    BMI_CONCEPT              = 'BMI'

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
        'init_weight' => init_weight,
        'init_height' => init_height,
        'init_breastfeeding' => init_breastfeeding,
        'hiv_test_date' => hiv_test_date,
        'hiv_test_location' => hiv_test_location,
        'agrees_to_followup' => agrees_to_followup,
        'reason_for_art_eligibility' => reason_for_art_eligibility,
        'who_stage_criteria' => who_stage_criteria,
        'current_tb_status' => latest_obs_value(TB_STATUS_CONCEPT),
        'current_status_on_tb_treatment' => on_tb_treatment?,
        'current_patient_type' => latest_obs_value(PATIENT_TYPE_CONCEPT),
        'current_height' => latest_obs_numeric(HEIGHT_CONCEPT),
        'current_weight' => latest_obs_numeric(WEIGHT_CONCEPT),
        'current_outcome' => current_outcome,
        'current_regimen' => current_regimen,
        'tpt_status' => tpt_status_details,
        'tpt_completed' => tpt_completed?,
        'tpt_start_date' => tpt_start_date,
        'tpt_regimen' => tpt_regimen,
        'hiv_clinic_encounter' => hiv_clinic_encounter?,
        'is_alive' => is_alive?,
        'has_height_ever' => has_height_ever?,
        'ever_received_arvs' => ever_received_arvs?,
        'already_staged' => already_staged?,
        'isTransferIn' => is_transfer_in?,
        'receivedArvsAtOtherFacility' => received_arvs_at_other_facility,
        'hasTransferLetter' => has_transfer_letter?,
        'weightHistory' => build_weight_history,
        'regimenHistory' => build_regimen_history,
        'latest_viral_load' => latest_viral_load,
        'pulmonary_tb_within_last_2_years' => staging_condition_present?(PTB_WITHIN_2_YEARS_NAMES),
        'extrapulmonary_tb'                => staging_condition_present?(EPTB_NAMES),
        'pulmonary_tb_current'             => staging_condition_present?(PTB_CURRENT_NAMES),
        'kaposis_sarcoma'                  => staging_condition_present?(KAPOSIS_NAMES),
        'visits' => build_visits
      }
    end

    private

    # ── Preloading ───────────────────────────────────────────────────────────

    def preload_data
      @concept_id_map = fetch_concept_ids(
        [WEIGHT_CONCEPT, HEIGHT_CONCEPT, TB_STATUS_CONCEPT, PATIENT_TYPE_CONCEPT,
         PATIENT_PRESENT_CONCEPT, PREGNANT_CONCEPT, BREASTFEEDING_CONCEPT, SIDE_EFFECTS_CONCEPT,
         REFER_TO_CLINICIAN_CONCEPT, APPOINTMENT_DATE_CONCEPT, MEDICATION_ORDERS_CONCEPT,
         HAS_TRANSFER_LETTER_CONCEPT, DATE_ART_LAST_TAKEN_CONCEPT,
         TB_TREATMENT_START_DATE_CONCEPT, PILLS_BROUGHT_CONCEPT,
         CONFIRMATORY_HIV_TEST_DATE_CONCEPT, CONFIRMATORY_HIV_TEST_LOCATION_CONCEPT,
         AGREES_TO_FOLLOWUP_CONCEPT, REASON_FOR_ART_ELIGIBILITY_CONCEPT,
         WHO_STAGE_CRITERIA_CONCEPT, INIT_BREASTFEEDING_CONCEPT,
         AMOUNT_DISPENSED_CONCEPT, ADHERENCE_CONCEPT, BMI_CONCEPT]
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
      @staging_criteria       = load_staging_criteria
      @all_orders             = load_all_orders
      @visit_dates            = load_visit_dates
      @all_encounters_by_date = load_all_encounters
      @clinician_obs_dates    = load_clinician_obs_dates
      @pills_brought_by_date  = load_pills_brought
      @pills_dispensed_by_date = load_pills_dispensed
      @adherence_by_date      = load_adherence
      @viral_load_results, @viral_load_by_date = load_viral_load_results
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

    def load_pills_brought
      pills_concept_id = @concept_id_map[PILLS_BROUGHT_CONCEPT]
      return {} unless pills_concept_id

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DATE(o.obs_datetime) AS obs_date,
               d.name               AS drug_name,
               o.value_numeric      AS quantity
        FROM obs o
        INNER JOIN orders ord        ON ord.order_id = o.order_id AND ord.voided = 0
        INNER JOIN drug_order do_tbl ON do_tbl.order_id = ord.order_id
        INNER JOIN drug d            ON d.drug_id = do_tbl.drug_inventory_id
        WHERE o.person_id  = #{@patient_id}
          AND o.voided     = 0
          AND o.concept_id = #{pills_concept_id}
        ORDER BY o.obs_datetime DESC
      SQL

      rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, h|
        h[r['obs_date'].to_s] << { 'name' => r['drug_name'], 'quantity' => r['quantity'] }
      end
    end

    def load_pills_dispensed
      dispensed_concept_id = @concept_id_map[AMOUNT_DISPENSED_CONCEPT]
      return {} unless dispensed_concept_id

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DATE(o.obs_datetime) AS obs_date,
               d.name               AS drug_name,
               o.value_numeric      AS quantity
        FROM obs o
        INNER JOIN orders ord        ON ord.order_id = o.order_id AND ord.voided = 0
        INNER JOIN drug_order do_tbl ON do_tbl.order_id = ord.order_id
        INNER JOIN drug d            ON d.drug_id = do_tbl.drug_inventory_id
        WHERE o.person_id  = #{@patient_id}
          AND o.voided     = 0
          AND o.concept_id = #{dispensed_concept_id}
        ORDER BY o.obs_datetime DESC
      SQL

      rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, h|
        h[r['obs_date'].to_s] << { 'name' => r['drug_name'], 'quantity' => r['quantity'] }
      end
    end

    def load_adherence
      adherence_concept_id = @concept_id_map[ADHERENCE_CONCEPT]
      return {} unless adherence_concept_id

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DATE(o.obs_datetime) AS obs_date,
               d.name               AS drug_name,
               o.value_numeric      AS adherence_numeric,
               o.value_text         AS adherence_text
        FROM obs o
        INNER JOIN orders ord        ON ord.order_id = o.order_id AND ord.voided = 0
        INNER JOIN drug_order do_tbl ON do_tbl.order_id = ord.order_id
        INNER JOIN drug d            ON d.drug_id = do_tbl.drug_inventory_id
        WHERE o.person_id  = #{@patient_id}
          AND o.voided     = 0
          AND o.concept_id = #{adherence_concept_id}
        ORDER BY o.obs_datetime DESC
      SQL

      rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, h|
        value = r['adherence_numeric'] ||
                r['adherence_text']&.gsub(/%$/, '')&.then { |v| v.empty? ? nil : v.to_f }
        h[r['obs_date'].to_s] << { 'drug' => r['drug_name'], 'adherence' => value }
      end
    end

    def load_viral_load_results
      test_type_id  = ConceptName.find_by(name: TEST_TYPE_CONCEPT)&.concept_id
      hiv_vl_id     = ConceptName.find_by(name: HIV_VIRAL_LOAD_CONCEPT)&.concept_id
      lab_result_id = ConceptName.find_by(name: LAB_TEST_RESULT_CONCEPT)&.concept_id
      return [[], {}] unless test_type_id && hiv_vl_id && lab_result_id

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT DATE(o.obs_datetime) AS obs_date,
               CONCAT(
                 COALESCE(r.value_modifier, ''),
                 COALESCE(CAST(r.value_numeric AS CHAR), ''),
                 COALESCE(r.value_text, '')
               )                   AS vl_value
        FROM obs o
        INNER JOIN obs tr ON tr.obs_group_id = o.obs_id
                         AND tr.voided       = 0
                         AND tr.concept_id   = #{lab_result_id}
        INNER JOIN obs r  ON r.obs_group_id  = tr.obs_id
                         AND r.voided        = 0
                         AND r.concept_id    = #{hiv_vl_id}
        WHERE o.person_id   = #{@patient_id}
          AND o.voided      = 0
          AND o.concept_id  = #{test_type_id}
          AND o.value_coded = #{hiv_vl_id}
          AND (r.value_numeric IS NOT NULL OR r.value_text IS NOT NULL)
        ORDER BY o.obs_datetime DESC
      SQL

      by_date = rows.each_with_object({}) do |r, h|
        h[r['obs_date'].to_s] ||= r['vl_value']
      end

      [rows, by_date]
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

    def init_weight
      (@all_obs[@concept_id_map[WEIGHT_CONCEPT]] || []).last&.dig('value_numeric')
    end

    def init_height
      (@all_obs[@concept_id_map[HEIGHT_CONCEPT]] || []).last&.dig('value_numeric')
    end

    def init_breastfeeding
      concept_id = @concept_id_map[INIT_BREASTFEEDING_CONCEPT]
      return false unless concept_id

      rows = @all_obs[concept_id] || []
      first_obs = rows.min_by { |r| r['obs_date'] }
      return false unless first_obs

      truthy_value?(first_obs)
    end

    def hiv_test_date
      concept_id = @concept_id_map[CONFIRMATORY_HIV_TEST_DATE_CONCEPT]
      return nil unless concept_id

      dt = (@all_obs[concept_id] || []).first&.dig('value_datetime')&.to_s
      dt.presence&.split(' ')&.first
    end

    def hiv_test_location
      concept_id = @concept_id_map[CONFIRMATORY_HIV_TEST_LOCATION_CONCEPT]
      return nil unless concept_id

      (@all_obs[concept_id] || []).first&.dig('value_text').presence
    end

    def agrees_to_followup
      concept_id = @concept_id_map[AGREES_TO_FOLLOWUP_CONCEPT]
      return false unless concept_id

      row = (@all_obs[concept_id] || []).first
      return false unless row

      truthy_value?(row)
    end

    def reason_for_art_eligibility
      concept_id = @concept_id_map[REASON_FOR_ART_ELIGIBILITY_CONCEPT]
      return nil unless concept_id

      row = (@all_obs[concept_id] || []).first
      row&.dig('value_coded_name').presence
    end

    def who_stage_criteria
      concept_id = @concept_id_map[WHO_STAGE_CRITERIA_CONCEPT]
      return [] unless concept_id

      (@all_obs[concept_id] || []).filter_map { |r| r['value_coded_name'].presence }.uniq
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

    # ── Transfer-in / history ────────────────────────────────────────────────

    def has_transfer_letter?
      rows = @all_obs[@concept_id_map[HAS_TRANSFER_LETTER_CONCEPT]] || []
      rows.any? { |r| truthy_value?(r) }
    end

    def is_transfer_in?
      return true if has_transfer_letter?

      latest_obs_value(PATIENT_TYPE_CONCEPT)&.match?(/transfer\s*in/i) || false
    end

    def received_arvs_at_other_facility
      return 'Yes' if has_transfer_letter?

      concept_id = @concept_id_map[DATE_ART_LAST_TAKEN_CONCEPT]
      return nil unless concept_id

      dt = (@all_obs[concept_id] || []).first&.dig('value_datetime')&.to_s
      dt.presence&.split(' ')&.first
    end

    def build_weight_history
      concept_id = @concept_id_map[WEIGHT_CONCEPT]
      return [] unless concept_id

      (@all_obs[concept_id] || []).map do |r|
        { 'date' => r['obs_date'].to_s, 'weight' => r['value_numeric'] }
      end
    end

    def build_regimen_history
      arv_order_dates = @all_orders.select do |_date, rows|
        rows.any? { |r| @arv_drug_ids.include?(r['drug_inventory_id']) }
      end.keys.sort.reverse

      arv_order_dates.each_with_object([]) do |date_str, history|
        row = ActiveRecord::Base.connection.select_one(
          "SELECT patient_current_regimen(#{@patient_id}, '#{date_str} 23:59:59') AS regimen"
        )
        regimen = row&.dig('regimen').presence
        history << { 'date' => date_str, 'regimen' => regimen } if regimen
      end
    end

    def latest_viral_load
      @viral_load_results.first&.dig('vl_value')
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

      arv_drugs = orders_on_date.select { |r| @arv_drug_ids.include?(r['drug_inventory_id']) }
                                .uniq { |r| r['drug_name'] }
                                .map do |r|
        { 'drug_id' => r['drug_inventory_id'], 'name' => r['drug_name'],
          'quantity' => r['quantity'] }
      end
      other_drugs = orders_on_date.select { |r| @tpt_drug_ids.include?(r['drug_inventory_id']) }
                                  .map { |r| r['drug_name'] }.uniq

      outcome_row = ActiveRecord::Base.connection.select_one(
        "SELECT patient_outcome(#{@patient_id}, '#{date_str} 23:59:59') AS outcome"
      )
      regimen_row = ActiveRecord::Base.connection.select_one(
        "SELECT patient_current_regimen(#{@patient_id}, '#{date_str} 23:59:59') AS regimen"
      )

      {
        'weight'                    => obs_numeric_on(obs_on_date, WEIGHT_CONCEPT),
        'height'                    => obs_numeric_on(obs_on_date, HEIGHT_CONCEPT),
        'bmi'                       => bmi_for(obs_on_date),
        'outcome'                   => outcome_row&.dig('outcome'),
        'regimen'                   => regimen_row&.dig('regimen').presence,
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
        'hasAppointment'            => encounter_done_on?(date_str, APPOINTMENT_ENCOUNTER),
        'pillsBroughtToClinic'      => pills_brought_on(date_str),
        'pills_dispensed'           => pills_dispensed_on(date_str),
        'adherence'                 => adherence_on(date_str),
        'tbTreatmentStartDate'      => tb_treatment_start_date_on(obs_on_date),
        'viral_load'                => viral_load_on(date_str)
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

    def ever_had_obs?(concept_name)
      concept_id = @concept_id_map[concept_name]
      return false unless concept_id

      (@all_obs[concept_id] || []).any? { |r| truthy_value?(r) }
    end

    def staging_condition_present?(concept_names)
      ids = ConceptName.where(name: concept_names).pluck(:concept_id).uniq
      ids.any? { |id| @staging_criteria.include?(id) }
    end

    def load_staging_criteria
      who_cid = @concept_id_map[WHO_STAGES_CRITERIA_CONCEPT]
      return Set.new unless who_cid

      ids = ActiveRecord::Base.connection.exec_query(<<~SQL).map { |r| r['value_coded'].to_i }
        SELECT DISTINCT value_coded
        FROM obs
        WHERE person_id  = #{@patient_id}
          AND concept_id = #{who_cid}
          AND value_coded IS NOT NULL
          AND voided = 0
      SQL
      Set.new(ids)
    end

    def pills_brought_on(date_str)
      @pills_brought_by_date[date_str] || []
    end

    def pills_dispensed_on(date_str)
      @pills_dispensed_by_date[date_str] || []
    end

    def adherence_on(date_str)
      @adherence_by_date[date_str] || []
    end

    def bmi_for(obs_on_date)
      obs_numeric_on(obs_on_date, BMI_CONCEPT)
    end

    def tb_treatment_start_date_on(obs_on_date)
      concept_id = @concept_id_map[TB_TREATMENT_START_DATE_CONCEPT]
      return nil unless concept_id

      dt = obs_on_date[concept_id]&.dig('value_datetime')&.to_s
      dt.presence&.split(' ')&.first
    end

    def viral_load_on(date_str)
      @viral_load_by_date[date_str]
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

    def tpt_status_details
      result = ArtService::Reports::Pepfar::TptStatus.new(
        start_date: @as_of, end_date: @as_of, patient_id: @patient_id
      ).find_report
      result.merge('as_of' => Time.current.to_s)
    rescue StandardError => e
      Rails.logger.error("PatientSummaryBuilder#tpt_status_details failed for patient #{@patient_id}: #{e.message}")
      nil
    end
  end
end
