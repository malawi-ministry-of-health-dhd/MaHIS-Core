# frozen_string_literal: true

class RestoreCohortHelperViews < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW arv_drug AS
      SELECT drug.drug_id
      FROM drug
      WHERE drug.concept_id IN (
        SELECT concept_set.concept_id
        FROM concept_set
        WHERE concept_set.concept_set IN (
          SELECT concept_name.concept_id
          FROM concept_name
          WHERE LOWER(concept_name.name) = 'antiretroviral drugs'
            AND concept_name.voided = 0
        )
      )
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW reason_for_art_eligibility_obs AS
      SELECT obs.person_id,
             obs.concept_id,
             obs.obs_datetime,
             concept_name.name
      FROM obs
      LEFT JOIN concept_name
        ON concept_name.concept_id = obs.value_coded
       AND concept_name.concept_name_type = 'FULLY_SPECIFIED'
       AND concept_name.voided = 0
      WHERE obs.concept_id = 7563
        AND obs.voided = 0
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW hiv_staging_conditions_obs AS
      SELECT obs.obs_id,
             obs.person_id,
             obs.concept_id,
             obs.value_coded,
             obs.obs_datetime
      FROM obs
      WHERE obs.voided = 0
    SQL
  end

  def down
    %w[hiv_staging_conditions_obs reason_for_art_eligibility_obs arv_drug].each do |view|
      execute "DROP VIEW IF EXISTS #{view}"
    end
  end
end
