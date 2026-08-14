# frozen_string_literal: true

class FixDateAntiretroviralsStartedFunction < ActiveRecord::Migration[8.1]
  def up
    execute 'DROP FUNCTION IF EXISTS date_antiretrovirals_started'

    execute <<~SQL
      CREATE FUNCTION date_antiretrovirals_started(set_patient_id INT, min_state_date DATE)
      RETURNS DATE
      DETERMINISTIC
      BEGIN
        DECLARE date_started DATE;
        DECLARE estimated_art_date_months VARCHAR(45);
        DECLARE art_start_concept_id INT;

        SET art_start_concept_id = (
          SELECT concept_id
          FROM concept_name
          WHERE name = 'Date antiretrovirals started'
            AND concept_name_type = 'FULLY_SPECIFIED'
            AND voided = 0
          LIMIT 1
        );

        SET date_started = (
          SELECT DATE(value_datetime)
          FROM obs
          WHERE concept_id = art_start_concept_id
            AND encounter_id > 0
            AND person_id = set_patient_id
            AND voided = 0
          ORDER BY obs_datetime, obs_id
          LIMIT 1
        );

        IF date_started IS NULL THEN
          SET estimated_art_date_months = (
            SELECT value_text
            FROM obs
            WHERE encounter_id > 0
              AND concept_id = art_start_concept_id
              AND person_id = set_patient_id
              AND voided = 0
            ORDER BY obs_datetime, obs_id
            LIMIT 1
          );

          SET min_state_date = (
            SELECT obs_datetime
            FROM obs
            WHERE encounter_id > 0
              AND concept_id = art_start_concept_id
              AND person_id = set_patient_id
              AND voided = 0
            ORDER BY obs_datetime, obs_id
            LIMIT 1
          );

          IF estimated_art_date_months = '6 months' THEN
            SET date_started = DATE_SUB(min_state_date, INTERVAL 6 MONTH);
          ELSEIF estimated_art_date_months = '12 months' THEN
            SET date_started = DATE_SUB(min_state_date, INTERVAL 12 MONTH);
          ELSEIF estimated_art_date_months = '18 months' THEN
            SET date_started = DATE_SUB(min_state_date, INTERVAL 18 MONTH);
          ELSEIF estimated_art_date_months = '24 months' THEN
            SET date_started = DATE_SUB(min_state_date, INTERVAL 24 MONTH);
          ELSEIF estimated_art_date_months = '48 months' THEN
            SET date_started = DATE_SUB(min_state_date, INTERVAL 48 MONTH);
          ELSEIF estimated_art_date_months = 'Over 2 years' THEN
            SET date_started = DATE_SUB(min_state_date, INTERVAL 60 MONTH);
          ELSE
            SET date_started = patient_start_date(set_patient_id);
          END IF;
        END IF;

        RETURN date_started;
      END
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'The previous date_antiretrovirals_started function used obsolete concept ID 2516'
  end
end
