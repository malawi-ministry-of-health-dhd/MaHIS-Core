# frozen_string_literal: true

class CreateArvDrugView < ActiveRecord::Migration[7.0]
  def up
    # Drop the view if it exists
    execute <<-SQL
      DROP VIEW IF EXISTS arv_drug;
    SQL

    # Create the arv_drug view that dynamically references the "Antiretroviral drugs" concept set
    # This view lists all drugs whose concept_id is in the Antiretroviral drugs concept set
    execute <<-SQL
      CREATE ALGORITHM=UNDEFINED 
      DEFINER=`root`@`localhost` 
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
    execute <<-SQL
      DROP VIEW IF EXISTS arv_drug;
    SQL
  end
end
