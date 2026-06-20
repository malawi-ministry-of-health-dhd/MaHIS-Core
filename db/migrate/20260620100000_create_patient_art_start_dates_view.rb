# frozen_string_literal: true

class CreatePatientArtStartDatesView < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW patient_art_start_dates AS
      SELECT obs.person_id AS patient_id,
             MIN(DATE(obs.obs_datetime)) AS art_start_date
      FROM obs
      INNER JOIN concept_name AS dispensation_concept
        ON dispensation_concept.concept_id = obs.concept_id
       AND LOWER(dispensation_concept.name) = 'amount dispensed'
      INNER JOIN drug ON drug.drug_id = obs.value_drug
      INNER JOIN concept_set ON concept_set.concept_id = drug.concept_id
      INNER JOIN concept_name AS arv_concept
        ON arv_concept.concept_id = concept_set.concept_set
       AND LOWER(arv_concept.name) = 'antiretroviral drugs'
      WHERE obs.voided = 0
      GROUP BY obs.person_id
    SQL
  end

  def down
    execute 'DROP VIEW IF EXISTS patient_art_start_dates'
  end
end
