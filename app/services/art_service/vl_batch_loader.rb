# frozen_string_literal: true

require 'ostruct'

module ArtService
  ##
  # Batch preloads viral load lab orders/results for a set of patients in a
  # handful of queries instead of ArtService::VlReminder and
  # ArtService::Reports::ViralLoad each issuing their own SQL per patient
  # (this backs the "Clients due for viral load" report, which can process
  # hundreds of patients per request).
  class VlBatchLoader
    RECENT_SPECIMEN_NAMES = ['Blood', 'DBS (Free drop to DBS card)', 'DBS (Using capillary tube)', 'Plasma'].freeze
    LAST_SPECIMEN_NAMES = ['Blood', 'DBS (Free drop to DBS card)', 'DBS (Using capillary tube)'].freeze
    PREGNANT_CONCEPT_NAMES = ['Is patient pregnant?', 'patient pregnant'].freeze
    BREAST_FEEDING_CONCEPT_NAMES = ['Breast feeding?', 'Breast feeding', 'Breastfeeding'].freeze
    CONSULTATION_ENCOUNTER_NAMES = ['HIV CLINIC CONSULTATION', 'HIV STAGING'].freeze
    REGIMEN_SWITCH_CONCEPT_NAME = 'Reason antiretrovirals substitute or switch (first line only)'

    def initialize(patient_ids:, start_date:, end_date:)
      @patient_ids = patient_ids.map(&:to_i)
      @start_date = start_date.to_date
      @end_date = end_date.to_date
      @recent_orders = {}
      @last_orders = {}
      @last_vl_results = {}
      @earliest_start_dates = {}
      @regimen_trails = {}
      @regimen_switch_obs = {}
      @viral_load_skips = {}
      @formatted_usernames = {}
      @pregnant = {}
      @breast_feeding = {}
      @filing_numbers = {}
      preload
    end

    # Mirrors ArtService::VlReminder#find_patient_recent_viral_load
    def recent_viral_load(patient_id, date, duration)
      window_start = date - duration
      (@recent_orders[patient_id] || [])
        .select { |order| order.start_date.to_date.between?(window_start, date) }
        .max_by(&:start_date)
    end

    # Mirrors ArtService::VlReminder#find_patient_last_viral_load
    def last_viral_load(patient_id, date)
      (@last_orders[patient_id] || [])
        .select { |order| order.start_date.to_date <= date }
        .max_by(&:start_date)
    end

    # Mirrors ArtService::Reports::ViralLoad#last_vl_result
    def last_vl_result(patient_id)
      (@last_vl_results[patient_id] || []).first
    end

    def earliest_start_date(patient_id)
      @earliest_start_dates[patient_id.to_i]
    end


    def regimen_trail(patient_id)
      @regimen_trails[patient_id.to_i] || []
    end


    def recent_regimen_switch(patient_id, from_date, to_date)
      (@regimen_switch_obs[patient_id.to_i] || [])
        .select { |obs| obs.value_text == 'Treatment failure' }
        .select { |obs| obs.obs_datetime.to_date.between?(from_date.to_date, to_date.to_date) }
        .max_by(&:obs_datetime)
    end

    def reason_for_regimen_switch(patient_id, visit_date)
      visit_date = visit_date.to_date
      (@regimen_switch_obs[patient_id.to_i] || [])
        .select { |obs| obs.obs_datetime.to_date.between?(visit_date, visit_date + 1.day) }
        .max_by(&:obs_datetime)
        &.value_text
    end

    def recent_viral_load_skip(patient_id, date, duration)
      window_start = date - duration
      (@viral_load_skips[patient_id.to_i] || [])
        .select { |obs| obs.obs_datetime.to_date.between?(window_start, date) }
        .max_by(&:obs_datetime)
    end

    def formatted_username(user_id)
      @formatted_usernames[user_id.to_i] || '(unknown)'
    end

    # Mirrors ArtService::VlReminder#patient_pregnant?
    def pregnant?(patient_id)
      @pregnant[patient_id.to_i] || false
    end

    # Mirrors ArtService::VlReminder#patient_breast_feeding?
    def breast_feeding?(patient_id)
      @breast_feeding[patient_id.to_i] || false
    end

    # Mirrors ArtService::VlReminder#patient_using_pead_regimen? using the most
    # recent regimen string from the regimen trail.
    def pead_regimen?(patient_id)
      regimen = regimen_trail(patient_id).first&.regimen
      return false if regimen.blank?

      regimen.include?('P')
    end

    # Mirrors ArtService::Reports::ViralLoad#use_filing_number filing lookup.
    def filing_number(patient_id)
      @filing_numbers[patient_id.to_i] || ''
    end

    private

    def preload
      return if @patient_ids.blank?

      preload_viral_load_orders
      preload_last_vl_results
      preload_earliest_start_dates
      preload_regimen_trails
      preload_regimen_switch_obs
      preload_viral_load_skips
      preload_pregnant_and_breast_feeding
      preload_filing_numbers
    end

    def viral_load_tests
      Observation.where(concept: ConceptName.where(name: 'Test type').select(:concept_id),
                        value_coded: ConceptName.where(name: 'Viral Load').select(:concept_id))
    end

    def preload_viral_load_orders
      # 12 months is the only duration ever used for the "recent" lookup, so a
      # single lookback bound covers every patient in the batch.
      lookback_start = @start_date - 12.months

      recent_specimens = ConceptName.where(name: RECENT_SPECIMEN_NAMES).select(:concept_id)
      @recent_orders = Lab::LabOrder.where(concept: recent_specimens, patient_id: @patient_ids)
                                    .where('start_date BETWEEN DATE(?) AND DATE(?)', lookback_start, @end_date)
                                    .joins(:tests)
                                    .merge(viral_load_tests)
                                    .group_by(&:patient_id)

      last_specimens = ConceptName.where(name: LAST_SPECIMEN_NAMES).select(:concept_id)
      @last_orders = Lab::LabOrder.where(concept: last_specimens, patient_id: @patient_ids)
                                  .where('start_date <= DATE(?)', @end_date)
                                  .joins(:tests)
                                  .merge(viral_load_tests)
                                  .group_by(&:patient_id)
    end

    def preload_last_vl_results
      viral_load_concept = ConceptName.where(name: 'HIV Viral Load').select(:concept_id)
      result_sql = <<~SQL
        INNER JOIN obs AS parent
          ON parent.obs_id = obs.obs_group_id
          AND parent.concept_id IN (SELECT concept_id FROM concept_name WHERE name = 'Lab test result' AND voided = 0)
          AND parent.voided = 0
          AND parent.person_id = obs.person_id
      SQL

      rows = Observation.joins(result_sql)
                        .joins('LEFT JOIN orders ON orders.order_id = obs.order_id')
                        .where(concept: viral_load_concept, person_id: @patient_ids)
                        .where('(obs.value_numeric IS NOT NULL OR obs.value_text IS NOT NULL)
                            AND obs.obs_datetime < DATE(?) + INTERVAL 1 DAY', @end_date)
                        .order(obs_datetime: :desc)
                        .pluck('obs.person_id',
                               Arel.sql("DATE_FORMAT(orders.start_date, '%Y-%m-%d')"),
                               Arel.sql("DATE_FORMAT(obs.obs_datetime, '%Y-%m-%d')"),
                               'obs.value_modifier', 'obs.value_numeric', 'obs.value_text')

      @last_vl_results = {}
      rows.each do |person_id, order_date, result_date, modifier, numeric, text|
        person_id = person_id.to_i
        next if @last_vl_results.key?(person_id)

        @last_vl_results[person_id] = [OpenStruct.new(
          order: OpenStruct.new(start_date: order_date),
          obs_datetime: result_date,
          value_modifier: modifier,
          value_numeric: numeric,
          value_text: text
        )]
      end
    end

    def preload_earliest_start_dates
      connection = ActiveRecord::Base.connection
      rows = connection.select_all(<<~SQL)
        WITH art_start_obs AS (
          SELECT o.person_id AS patient_id,
                 NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(COALESCE(DATE(o.value_datetime), '__NULL__') ORDER BY o.obs_id), ',', 1), '__NULL__') AS value_date,
                 NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(COALESCE(o.value_text, '__NULL__') ORDER BY o.obs_id), ',', 1), '__NULL__') AS estimated_duration,
                 SUBSTRING_INDEX(GROUP_CONCAT(DATE(o.obs_datetime) ORDER BY o.obs_id), ',', 1) AS observed_date
          FROM obs o
          WHERE o.person_id IN (#{patient_ids_sql})
            AND o.concept_id = 2516
            AND o.encounter_id > 0
            AND o.voided = 0
          GROUP BY o.person_id
        ), dispensation_dates AS (
          SELECT o.person_id AS patient_id, MIN(DATE(o.obs_datetime)) AS start_date
          FROM obs o
          INNER JOIN drug d ON d.drug_id = o.value_drug
          INNER JOIN concept_set cs ON cs.concept_id = d.concept_id
          WHERE o.person_id IN (#{patient_ids_sql})
            AND o.voided = 0
            AND o.concept_id = (SELECT concept_id FROM concept_name WHERE name = 'AMOUNT DISPENSED' LIMIT 1)
            AND cs.concept_set = (SELECT concept_id FROM concept_name WHERE name = 'ANTIRETROVIRAL DRUGS' LIMIT 1)
          GROUP BY o.person_id
        )
        SELECT p.patient_id,
               COALESCE(
                 s.value_date,
                 CASE s.estimated_duration
                   WHEN '6 months' THEN DATE_SUB(s.observed_date, INTERVAL 6 MONTH)
                   WHEN '12 months' THEN DATE_SUB(s.observed_date, INTERVAL 12 MONTH)
                   WHEN '18 months' THEN DATE_SUB(s.observed_date, INTERVAL 18 MONTH)
                   WHEN '24 months' THEN DATE_SUB(s.observed_date, INTERVAL 24 MONTH)
                   WHEN '48 months' THEN DATE_SUB(s.observed_date, INTERVAL 48 MONTH)
                   WHEN 'Over 2 years' THEN DATE_SUB(s.observed_date, INTERVAL 60 MONTH)
                   ELSE d.start_date
                 END
               ) AS start_date
        FROM patient p
        LEFT JOIN art_start_obs s ON s.patient_id = p.patient_id
        LEFT JOIN dispensation_dates d ON d.patient_id = p.patient_id
        WHERE p.patient_id IN (#{patient_ids_sql})
      SQL

      rows.each do |row|
        @earliest_start_dates[row['patient_id'].to_i] = row['start_date']&.to_date
      end

      missing_ids = @patient_ids.select { |patient_id| @earliest_start_dates[patient_id].nil? }
      return if missing_ids.blank?

      PatientProgram.where(patient_id: missing_ids, program: Program.find_by_name('HIV Program'))
                    .pluck(:patient_id, :date_enrolled)
                    .each do |patient_id, date_enrolled|
        @earliest_start_dates[patient_id.to_i] ||= date_enrolled&.to_date
      end
    end

    def preload_regimen_trails
      rows = ActiveRecord::Base.connection.select_all(<<~SQL)
        WITH eligible_orders AS (
          SELECT o.patient_id, DATE(o.start_date) AS order_date, o.auto_expire_date
          FROM orders o
          INNER JOIN drug_order d ON d.order_id = o.order_id
          WHERE o.patient_id IN (#{patient_ids_sql})
            AND o.voided = 0
            AND o.order_type_id = (SELECT order_type_id FROM order_type WHERE name = 'Drug order' LIMIT 1)
            AND o.concept_id IN (
              SELECT cs.concept_id
              FROM concept_set cs
              WHERE cs.concept_set = (
                SELECT concept_id FROM concept_name WHERE name = 'Antiretroviral drugs' LIMIT 1
              )
            )
        ), order_dates AS (
          SELECT DISTINCT patient_id, order_date FROM eligible_orders
        ), latest_times AS (
          SELECT od.patient_id, od.order_date, MAX(o.start_date) AS latest_start
          FROM order_dates od
          INNER JOIN orders o
            ON o.patient_id = od.patient_id
            AND o.start_date < od.order_date + INTERVAL 1 DAY
            AND o.voided = 0
          INNER JOIN drug_order d ON d.order_id = o.order_id AND d.quantity > 0
          INNER JOIN arv_drug a ON a.drug_id = d.drug_inventory_id
          GROUP BY od.patient_id, od.order_date
        ), prescribed_drugs AS (
          SELECT lt.patient_id, lt.order_date,
                 GROUP_CONCAT(DISTINCT d.drug_inventory_id ORDER BY d.drug_inventory_id) AS drugs
          FROM latest_times lt
          INNER JOIN orders o
            ON o.patient_id = lt.patient_id
            AND o.start_date = lt.latest_start
            AND o.voided = 0
          INNER JOIN drug_order d ON d.order_id = o.order_id AND d.quantity > 0
          INNER JOIN arv_drug a ON a.drug_id = d.drug_inventory_id
          INNER JOIN encounter e
            ON e.encounter_id = o.encounter_id
            AND e.voided = 0
            AND e.encounter_type = 25
          GROUP BY lt.patient_id, lt.order_date
        ), definitions AS (
          SELECT c.regimen_combination_id, n.name,
                 GROUP_CONCAT(cd.drug_id ORDER BY cd.drug_id) AS drugs
          FROM moh_regimen_combination c
          INNER JOIN moh_regimen_combination_drug cd USING (regimen_combination_id)
          INNER JOIN moh_regimen_name n USING (regimen_name_id)
          GROUP BY c.regimen_combination_id, n.name
        ), mapped_orders AS (
          SELECT eo.patient_id, eo.order_date, eo.auto_expire_date,
                 COALESCE(definitions.name, 'N/A') AS regimen
          FROM eligible_orders eo
          LEFT JOIN prescribed_drugs pd
            ON pd.patient_id = eo.patient_id
            AND pd.order_date = eo.order_date
          LEFT JOIN definitions ON definitions.drugs = pd.drugs
        )
        SELECT patient_id, regimen, MIN(order_date) AS start_date,
               DATE(MAX(auto_expire_date)) AS auto_expire_date
        FROM mapped_orders
        GROUP BY patient_id, regimen
        ORDER BY patient_id, start_date DESC
      SQL

      rows.each do |row|
        patient_id = row['patient_id'].to_i
        @regimen_trails[patient_id] ||= []
        next if @regimen_trails[patient_id].size >= 2

        @regimen_trails[patient_id] << OpenStruct.new(regimen: row['regimen'],
                                                       date_started: row['start_date']&.to_date,
                                                       date_completed: row['auto_expire_date']&.to_date)
      end
    end

    def patient_ids_sql
      @patient_ids.join(',')
    end

    ##
    # Bulk-loads ALL observations for the regimen-switch concept per patient
    # (no value_text restriction). Both recent_regimen_switch (filters
    # value_text = 'Treatment failure' in Ruby) and reason_for_regimen_switch
    # are derived from this one preloaded set.
    def preload_regimen_switch_obs
      regimen_switch_concept = ConceptName.where(name: REGIMEN_SWITCH_CONCEPT_NAME).select(:concept_id)

      rows = Observation.where(concept: regimen_switch_concept, person_id: @patient_ids)
                        .where('obs_datetime <= DATE(?) + INTERVAL 1 DAY', @end_date)
                        .order(:obs_datetime)
                        .pluck(:person_id,
                               Arel.sql("DATE_FORMAT(obs_datetime, '%Y-%m-%d %H:%i:%s')"),
                               :value_text)

      @regimen_switch_obs = rows.group_by(&:first).transform_values do |patient_rows|
        patient_rows.map do |_person_id, obs_datetime, value_text|
          OpenStruct.new(obs_datetime:, value_text:)
        end
      end
    end

    def preload_viral_load_skips
      concepts = ConceptName.where(name: ['Delayed milestones', 'Tests ordered']).select(:concept_id)
      lookback_start = @start_date - 12.months

      rows = Observation.where(concept: concepts, person_id: @patient_ids)
                        .where('obs_datetime BETWEEN DATE(?) AND DATE(?)', lookback_start, @end_date)
                        .order(:obs_datetime)
                        .pluck(:person_id,
                               Arel.sql("DATE_FORMAT(obs_datetime, '%Y-%m-%d %H:%i:%s')"),
                               :creator)

      @viral_load_skips = rows.group_by(&:first).transform_values do |patient_rows|
        patient_rows.map do |_person_id, obs_datetime, creator|
          OpenStruct.new(obs_datetime:, creator:)
        end
      end

      creator_ids = @viral_load_skips.values.flatten.map(&:creator).compact.uniq
      return if creator_ids.blank?

      users = User.unscoped.where(user_id: creator_ids).index_by(&:user_id)
      names = PersonName.unscoped.where(person_id: users.values.map(&:person_id).compact.uniq).index_by(&:person_id)

      users.each do |user_id, user|
        name = names[user.person_id]
        @formatted_usernames[user_id.to_i] = name ? "#{name.given_name} #{name.family_name} (#{user.username})" : "(#{user.username})"
      end
    end

    ##
    # Bulk-loads latest pregnant / breast-feeding obs per patient.
    def preload_pregnant_and_breast_feeding
      @pregnant = latest_yes_obs_per_patient(pregnant_concepts)
      @breast_feeding = latest_yes_obs_per_patient(breast_feeding_concepts)
    end

    def latest_yes_obs_per_patient(concepts)
      result = {}
      rows = Observation.joins(:encounter)
                        .where(encounter: { encounter_type: encounter_types, voided: 0 })
                        .where(concept: concepts, person_id: @patient_ids, voided: 0)
                        .where('obs.obs_datetime < DATE(?) + INTERVAL 1 DAY', @end_date)
                        .order(obs_datetime: :desc)
                        .pluck(:person_id, :value_coded)

      rows.each do |patient_id, value_coded|
        patient_id = patient_id.to_i
        next if result.key?(patient_id)

        result[patient_id] = yes_concepts.include?(value_coded.to_i)
      end

      result
    end

    def preload_filing_numbers
      identifier_types = PatientIdentifierType.where("name LIKE '%Filing number%'")
                                              .map(&:patient_identifier_type_id)
      return if identifier_types.blank?

      grouped = PatientIdentifier.where(patient_id: @patient_ids, identifier_type: identifier_types)
                                 .pluck(:patient_id, :identifier)
                                 .group_by(&:first)

      grouped.each do |patient_id, identifiers|
        @filing_numbers[patient_id.to_i] = identifiers.last&.last || ''
      end
    end

    def yes_concepts
      @yes_concepts ||= ConceptName.where(name: 'Yes').select(:concept_id).map { |record| record['concept_id'].to_i }
    end

    def pregnant_concepts
      @pregnant_concepts ||= ConceptName.where(name: PREGNANT_CONCEPT_NAMES).select(:concept_id)
    end

    def breast_feeding_concepts
      @breast_feeding_concepts ||= ConceptName.where(name: BREAST_FEEDING_CONCEPT_NAMES).select(:concept_id)
    end

    def encounter_types
      @encounter_types ||= EncounterType.where(name: CONSULTATION_ENCOUNTER_NAMES).select(:encounter_type_id)
    end
  end
end
