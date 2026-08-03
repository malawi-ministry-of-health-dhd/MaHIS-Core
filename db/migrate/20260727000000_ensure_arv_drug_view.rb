# frozen_string_literal: true

class EnsureArvDrugView < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE
      SQL SECURITY INVOKER
      VIEW arv_drug AS
      SELECT drug.drug_id AS drug_id
      FROM drug
      WHERE drug.concept_id IN (
        SELECT concept_set.concept_id
        FROM concept_set
        WHERE concept_set.concept_set = (
          SELECT concept_id
          FROM concept_name
          WHERE name = 'Antiretroviral drugs'
          LIMIT 1
        )
      );
    SQL
  end

  def down
    execute 'DROP VIEW IF EXISTS arv_drug'
  end
end
