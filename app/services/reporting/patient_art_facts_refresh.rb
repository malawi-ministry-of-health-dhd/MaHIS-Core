# frozen_string_literal: true

require_relative '../../../lib/tidb_reporting'

module Reporting
  class PatientArtFactsRefresh
    REFRESH_SQL = <<~SQL.freeze
      INSERT INTO reporting_patient_art_facts (
        patient_id,
        location_id,
        program_state_start_date,
        date_enrolled,
        recorded_start_date,
        estimated_start_date,
        dispensation_start_date,
        earliest_start_date,
        created_at,
        updated_at
      )
      SELECT program_patients.patient_id,
             program_patients.location_id,
             program_patients.program_state_start_date,
             art_orders.date_enrolled,
             art_start_observations.recorded_start_date,
             art_start_observations.estimated_start_date,
             art_dispensations.dispensation_start_date,
             COALESCE(
               art_start_observations.recorded_start_date,
               art_start_observations.estimated_start_date,
               art_dispensations.dispensation_start_date,
               art_orders.date_enrolled
             ) AS earliest_start_date,
             CURRENT_TIMESTAMP,
             CURRENT_TIMESTAMP
      FROM (
        SELECT patient_program.patient_id,
               COALESCE(patient_program.location_id, 0) AS location_id,
               MIN(DATE(patient_state.start_date)) AS program_state_start_date
        FROM patient_program
        INNER JOIN patient_state
          ON patient_state.patient_program_id = patient_program.patient_program_id
         AND patient_state.state = 7
         AND patient_state.voided = 0
        WHERE patient_program.program_id = 1
          AND patient_program.voided = 0
        GROUP BY patient_program.patient_id, COALESCE(patient_program.location_id, 0)
      ) AS program_patients
      LEFT JOIN (
        SELECT orders.patient_id,
               MIN(DATE(orders.start_date)) AS date_enrolled
        FROM orders
        INNER JOIN drug_order
          ON drug_order.order_id = orders.order_id
         AND drug_order.quantity > 0
        INNER JOIN drug
          ON drug.drug_id = drug_order.drug_inventory_id
        INNER JOIN concept_set
          ON concept_set.concept_id = drug.concept_id
        INNER JOIN concept_name AS arv_concept
          ON arv_concept.concept_id = concept_set.concept_set
         AND arv_concept.name = 'Antiretroviral drugs'
         AND arv_concept.voided = 0
        WHERE orders.voided = 0
        GROUP BY orders.patient_id
      ) AS art_orders
        ON art_orders.patient_id = program_patients.patient_id
      LEFT JOIN (
        SELECT obs.person_id AS patient_id,
               MIN(DATE(obs.value_datetime)) AS recorded_start_date,
               MIN(
                 CASE obs.value_text
                   WHEN '6 months' THEN DATE_SUB(DATE(obs.obs_datetime), INTERVAL 6 MONTH)
                   WHEN '12 months' THEN DATE_SUB(DATE(obs.obs_datetime), INTERVAL 12 MONTH)
                   WHEN '18 months' THEN DATE_SUB(DATE(obs.obs_datetime), INTERVAL 18 MONTH)
                   WHEN '24 months' THEN DATE_SUB(DATE(obs.obs_datetime), INTERVAL 24 MONTH)
                   WHEN '48 months' THEN DATE_SUB(DATE(obs.obs_datetime), INTERVAL 48 MONTH)
                   WHEN 'Over 2 years' THEN DATE_SUB(DATE(obs.obs_datetime), INTERVAL 60 MONTH)
                 END
               ) AS estimated_start_date
        FROM obs
        WHERE obs.concept_id = 2516
          AND obs.encounter_id > 0
          AND obs.voided = 0
        GROUP BY obs.person_id
      ) AS art_start_observations
        ON art_start_observations.patient_id = program_patients.patient_id
      LEFT JOIN (
        SELECT obs.person_id AS patient_id,
               MIN(DATE(obs.obs_datetime)) AS dispensation_start_date
        FROM obs
        INNER JOIN concept_name
          ON concept_name.concept_id = obs.concept_id
         AND LOWER(concept_name.name) = 'amount dispensed'
         AND concept_name.voided = 0
        INNER JOIN drug
          ON drug.drug_id = obs.value_drug
        INNER JOIN concept_set
          ON concept_set.concept_id = drug.concept_id
        INNER JOIN concept_name AS arv_concept
          ON arv_concept.concept_id = concept_set.concept_set
         AND arv_concept.name = 'Antiretroviral drugs'
         AND arv_concept.voided = 0
        WHERE obs.voided = 0
        GROUP BY obs.person_id
      ) AS art_dispensations
        ON art_dispensations.patient_id = program_patients.patient_id
    SQL

    def self.call(connection: ActiveRecord::Base.connection)
      TidbReporting.with_analytics_session(connection, materialize: true) do |analytics_connection|
        analytics_connection.transaction do
          analytics_connection.execute('DELETE FROM reporting_patient_art_facts')
          analytics_connection.execute(REFRESH_SQL)
        end
      end

      connection.select_value('SELECT COUNT(*) FROM reporting_patient_art_facts').to_i
    end
  end
end
