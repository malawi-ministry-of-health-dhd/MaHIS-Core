# frozen_string_literal: true

# patient_current_regimen() hardcoded encounter.encounter_type = 25 for
# TREATMENT, but in this MaHIS database encounter_type_id 25 is "Examination"
# — TREATMENT is 22. The drug-matching subquery therefore always joined on
# the wrong encounter type, found no rows, and the function silently fell
# back to 'N/A' for every patient regardless of their actual regimen.
# Fixes it by resolving the TREATMENT encounter_type_id dynamically instead
# of hardcoding an id that isn't portable across sites.
class FixPatientCurrentRegimenTreatmentEncounterType < ActiveRecord::Migration[8.1]
  TREATMENT_ENCOUNTER_TYPE_LOOKUP_SQL = <<~SQL
    SELECT encounter_type_id FROM encounter_type
    WHERE name = 'TREATMENT' AND retired = 0
    ORDER BY encounter_type_id ASC
    LIMIT 1
  SQL

  def up
    execute('DROP FUNCTION IF EXISTS patient_current_regimen')
    execute(<<~SQL)
      CREATE FUNCTION `patient_current_regimen`(`my_patient_id` INT, `my_date` DATE) RETURNS varchar(10) CHARSET utf8mb3 COLLATE utf8mb3_unicode_ci
          DETERMINISTIC
      BEGIN
        DECLARE max_obs_datetime DATETIME;
        DECLARE regimen VARCHAR(10) DEFAULT 'N/A';
        DECLARE treatment_encounter_type_id INT;

        SET treatment_encounter_type_id = (
          #{TREATMENT_ENCOUNTER_TYPE_LOOKUP_SQL}
        );

        SET max_obs_datetime = (
          SELECT MAX(start_date)
          FROM orders
            INNER JOIN drug_order
              ON drug_order.order_id = orders.order_id
              AND drug_order.drug_inventory_id IN (SELECT * FROM arv_drug)
              AND orders.voided = 0
              AND DATE(orders.start_date) <= DATE(my_date)
          WHERE orders.patient_id = my_patient_id AND drug_order.quantity > 0
        );

        SET @drug_ids := (
          SELECT GROUP_CONCAT(DISTINCT(drug_order.drug_inventory_id) ORDER BY drug_order.drug_inventory_id ASC)
          FROM drug_order
            INNER JOIN arv_drug ON drug_order.drug_inventory_id = arv_drug.drug_id
            INNER JOIN orders ON drug_order.order_id = orders.order_id AND drug_order.quantity > 0
            INNER JOIN encounter
              ON encounter.encounter_id = orders.encounter_id
              AND encounter.voided = 0
              AND encounter.encounter_type = treatment_encounter_type_id
          WHERE orders.voided = 0
            AND date(orders.start_date) = DATE(max_obs_datetime)
            AND encounter.patient_id = my_patient_id
          ORDER BY arv_drug.drug_id ASC
        );

        SET regimen = (
          SELECT DISTINCT name FROM (
            SELECT GROUP_CONCAT(drug.drug_id ORDER BY drug.drug_id ASC) AS drugs,
                   regimen_name.name AS name
            FROM moh_regimen_combination AS combo
              INNER JOIN moh_regimen_combination_drug AS drug USING (regimen_combination_id)
              INNER JOIN moh_regimen_name AS regimen_name USING (regimen_name_id)
            GROUP BY combo.regimen_combination_id
          ) AS regimens
          WHERE drugs = @drug_ids
          LIMIT 1
        );

        IF regimen IS NULL THEN
          SET regimen = 'N/A';
        END IF;

        RETURN regimen;
      END
    SQL
  end

  def down
    execute('DROP FUNCTION IF EXISTS patient_current_regimen')
    execute(<<~SQL)
      CREATE FUNCTION `patient_current_regimen`(`my_patient_id` INT, `my_date` DATE) RETURNS varchar(10) CHARSET utf8mb3 COLLATE utf8mb3_unicode_ci
          DETERMINISTIC
      BEGIN
        DECLARE max_obs_datetime DATETIME;
        DECLARE regimen VARCHAR(10) DEFAULT 'N/A';

        SET max_obs_datetime = (
          SELECT MAX(start_date)
          FROM orders
            INNER JOIN drug_order
              ON drug_order.order_id = orders.order_id
              AND drug_order.drug_inventory_id IN (SELECT * FROM arv_drug)
              AND orders.voided = 0
              AND DATE(orders.start_date) <= DATE(my_date)
          WHERE orders.patient_id = my_patient_id AND drug_order.quantity > 0
        );

        SET @drug_ids := (
          SELECT GROUP_CONCAT(DISTINCT(drug_order.drug_inventory_id) ORDER BY drug_order.drug_inventory_id ASC)
          FROM drug_order
            INNER JOIN arv_drug ON drug_order.drug_inventory_id = arv_drug.drug_id
            INNER JOIN orders ON drug_order.order_id = orders.order_id AND drug_order.quantity > 0
            INNER JOIN encounter
              ON encounter.encounter_id = orders.encounter_id
              AND encounter.voided = 0
              AND encounter.encounter_type = 25
          WHERE orders.voided = 0
            AND date(orders.start_date) = DATE(max_obs_datetime)
            AND encounter.patient_id = my_patient_id
          ORDER BY arv_drug.drug_id ASC
        );

        SET regimen = (
          SELECT DISTINCT name FROM (
            SELECT GROUP_CONCAT(drug.drug_id ORDER BY drug.drug_id ASC) AS drugs,
                   regimen_name.name AS name
            FROM moh_regimen_combination AS combo
              INNER JOIN moh_regimen_combination_drug AS drug USING (regimen_combination_id)
              INNER JOIN moh_regimen_name AS regimen_name USING (regimen_name_id)
            GROUP BY combo.regimen_combination_id
          ) AS regimens
          WHERE drugs = @drug_ids
          LIMIT 1
        );

        IF regimen IS NULL THEN
          SET regimen = 'N/A';
        END IF;

        RETURN regimen;
      END
    SQL
  end
end
