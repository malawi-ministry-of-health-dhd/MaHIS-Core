# Recreates routines/views ported from a production dump with DEFINER=CURRENT_USER
# so they no longer reference the prod-only account 'mahisprod'@'10.44.8.40', which
# doesn't exist on dev/test/CI databases and breaks `db:schema:dump` (mysqldump error 1449)
# and view access for any account lacking SUPER/SET_USER_ID privilege.
class FixHardcodedProdDefinerOnFunctionsAndViews < ActiveRecord::Migration[7.0]
  DIED_IN_LOC_BODY = <<~SQL
    (set_patient_id INT, set_status VARCHAR(25), date_enrolled DATE) RETURNS varchar(25) CHARSET utf8mb3 COLLATE utf8mb3_unicode_ci
    DETERMINISTIC
    BEGIN
      DECLARE set_outcome varchar(25) default 'N/A';
      DECLARE date_of_death DATE;
      DECLARE num_of_days INT;

      IF set_status = 'Patient died' THEN
        SET date_of_death = (
          SELECT COALESCE(death_date, moh_outcome_date)
          FROM %<temp_outcomes>s INNER JOIN %<temp_earliest>s
          USING (patient_id)
          WHERE moh_cum_outcome = 'Patient died' AND patient_id = set_patient_id
        );

        IF date_of_death IS NULL THEN
          RETURN 'Unknown';
        END IF;

        set num_of_days = (TIMESTAMPDIFF(day, date(date_enrolled), date(date_of_death)));
        IF num_of_days <= 30 THEN set set_outcome ="1st month";
        ELSEIF num_of_days <= 60 THEN set set_outcome ="2nd month";
        ELSEIF num_of_days <= 91 THEN set set_outcome ="3rd month";
        ELSEIF num_of_days > 91 THEN set set_outcome ="4+ months";
        ELSEIF num_of_days IS NULL THEN set set_outcome = "Unknown";
        END IF;
      END IF;

      RETURN set_outcome;
    END
  SQL

  DIED_IN_LOC_SUFFIXES = %w[1217 32 58 79 927].freeze

  PATIENT_OUTCOME_BODY = <<~'SQL'
    (patient_id INT, visit_date date) RETURNS varchar(25) CHARSET utf8mb3 COLLATE utf8mb3_unicode_ci
    DETERMINISTIC
    BEGIN
    DECLARE set_program_id INT;
    DECLARE set_patient_state INT;
    DECLARE set_outcome varchar(25);
    DECLARE set_date_started date;
    DECLARE set_patient_state_died INT;
    DECLARE set_died_concept_id INT;
    DECLARE set_timestamp DATETIME;
    DECLARE dispensed_quantity INT;

    SET set_timestamp = TIMESTAMP(CONCAT(DATE(visit_date), ' ', '23:59:59'));
    SET set_program_id = (SELECT program_id FROM program WHERE name ="HIV PROGRAM" LIMIT 1);

    SET set_patient_state = (SELECT state FROM `patient_state` INNER JOIN patient_program p ON p.patient_program_id = patient_state.patient_program_id AND p.program_id = set_program_id WHERE (patient_state.voided = 0 AND p.voided = 0 AND p.program_id = program_id AND DATE(start_date) <= visit_date AND p.patient_id = patient_id) AND (patient_state.voided = 0) ORDER BY start_date DESC, patient_state.patient_state_id DESC, patient_state.date_created DESC LIMIT 1);

    IF set_patient_state = 1 THEN
      SET set_patient_state = current_defaulter(patient_id, set_timestamp);

      IF set_patient_state = 1 THEN
        SET set_outcome = 'Defaulted';
      ELSE
        SET set_outcome = 'Pre-ART (Continue)';
      END IF;
    END IF;

    IF set_patient_state = 2   THEN
      SET set_outcome = 'Patient transferred out';
    END IF;

    IF set_patient_state = 3 OR set_patient_state = 127 THEN
      SET set_outcome = 'Patient died';
    END IF;


    IF set_patient_state != 3 AND set_patient_state != 127 THEN
      SET set_patient_state_died = (SELECT state FROM `patient_state` INNER JOIN patient_program p ON p.patient_program_id = patient_state.patient_program_id AND p.program_id = set_program_id WHERE (patient_state.voided = 0 AND p.voided = 0 AND p.program_id = program_id AND DATE(start_date) <= visit_date AND p.patient_id = patient_id) AND (patient_state.voided = 0) AND state = 3 ORDER BY patient_state.patient_state_id DESC, patient_state.date_created DESC, start_date DESC LIMIT 1);

      SET set_died_concept_id = (SELECT concept_id FROM concept_name WHERE name = 'Patient died' LIMIT 1);

      IF set_patient_state_died IN(SELECT program_workflow_state_id FROM program_workflow_state WHERE concept_id = set_died_concept_id AND retired = 0) THEN
        SET set_outcome = 'Patient died';
        SET set_patient_state = 3;
      END IF;
    END IF;



    IF set_patient_state = 6 THEN
      SET set_outcome = 'Treatment stopped';
    END IF;

    IF set_patient_state = 7 OR set_outcome = 'Pre-ART (Continue)' OR set_outcome IS NULL THEN
      SET set_patient_state = current_defaulter(patient_id, set_timestamp);

      IF set_patient_state = 1 THEN
        SET set_outcome = 'Defaulted';
      END IF;

      IF set_patient_state = 0 OR set_outcome IS NULL THEN

        SET dispensed_quantity = (SELECT d.quantity
          FROM orders o
          INNER JOIN drug_order d ON d.order_id = o.order_id
          INNER JOIN drug ON drug.drug_id = d.drug_inventory_id
          WHERE o.patient_id = patient_id AND o.voided = 0
          AND d.drug_inventory_id IN(
            SELECT DISTINCT(drug_id) FROM drug WHERE
            concept_id IN(SELECT concept_id FROM concept_set WHERE concept_set=37989)
        ) AND DATE(o.start_date) <= visit_date AND d.quantity > 0 ORDER BY start_date DESC LIMIT 1);

        IF dispensed_quantity > 0 THEN
          SET set_outcome = 'On antiretrovirals';
        END IF;
      END IF;
    END IF;

    IF set_outcome IS NULL THEN
      SET set_patient_state = current_defaulter(patient_id, set_timestamp);

      IF set_patient_state = 1 THEN
        SET set_outcome = 'Defaulted';
      END IF;

      IF set_outcome IS NULL THEN
        SET set_outcome = 'Unknown';
      END IF;

    END IF;

    RETURN set_outcome;
    END
  SQL

  ARV_DRUG_VIEW = <<~SQL
    select `drug`.`drug_id` AS `drug_id` from `drug` where `drug`.`concept_id` in (select `concept_set`.`concept_id` from `concept_set` where (`concept_set`.`concept_set` = (select `concept_name`.`concept_id` from `concept_name` where (`concept_name`.`name` = 'Antiretroviral drugs') limit 1)))
  SQL

  CLINIC_REGISTRATION_ENCOUNTER_VIEW = <<~SQL
    select `e`.`encounter_id` AS `encounter_id`,`e`.`encounter_type` AS `encounter_type`,`e`.`patient_id` AS `patient_id`,`e`.`provider_id` AS `provider_id`,`e`.`location_id` AS `location_id`,`e`.`form_id` AS `form_id`,`e`.`encounter_datetime` AS `encounter_datetime`,`e`.`creator` AS `creator`,`e`.`date_created` AS `date_created`,`e`.`voided` AS `voided`,`e`.`voided_by` AS `voided_by`,`e`.`date_voided` AS `date_voided`,`e`.`void_reason` AS `void_reason`,`e`.`uuid` AS `uuid`,`e`.`changed_by` AS `changed_by`,`e`.`date_changed` AS `date_changed` from `encounter` `e` where ((`e`.`encounter_type` = (select `encounter_type`.`encounter_type_id` from `encounter_type` where (`encounter_type`.`name` = 'HIV CLINIC REGISTRATION') limit 1)) and (`e`.`voided` = 0))
  SQL

  EVER_REGISTERED_OBS_VIEW = <<~SQL
    select `obs`.`obs_id` AS `obs_id`,`obs`.`person_id` AS `person_id`,`obs`.`concept_id` AS `concept_id`,`obs`.`encounter_id` AS `encounter_id`,`obs`.`order_id` AS `order_id`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`location_id` AS `location_id`,`obs`.`obs_group_id` AS `obs_group_id`,`obs`.`accession_number` AS `accession_number`,`obs`.`value_group_id` AS `value_group_id`,`obs`.`value_boolean` AS `value_boolean`,`obs`.`value_coded` AS `value_coded`,`obs`.`value_coded_name_id` AS `value_coded_name_id`,`obs`.`value_drug` AS `value_drug`,`obs`.`value_datetime` AS `value_datetime`,`obs`.`value_numeric` AS `value_numeric`,`obs`.`value_modifier` AS `value_modifier`,`obs`.`value_text` AS `value_text`,`obs`.`date_started` AS `date_started`,`obs`.`date_stopped` AS `date_stopped`,`obs`.`comments` AS `comments`,`obs`.`creator` AS `creator`,`obs`.`date_created` AS `date_created`,`obs`.`voided` AS `voided`,`obs`.`voided_by` AS `voided_by`,`obs`.`date_voided` AS `date_voided`,`obs`.`void_reason` AS `void_reason`,`obs`.`value_complex` AS `value_complex`,`obs`.`uuid` AS `uuid` from `obs` where ((`obs`.`concept_id` = (select `concept_name`.`concept_id` from `concept_name` where (`concept_name`.`name` = 'Ever registered at ART clinic') limit 1)) and (`obs`.`voided` = 0) and (`obs`.`value_coded` = (select `concept_name`.`concept_id` from `concept_name` where (`concept_name`.`name` = 'Yes') limit 1)))
  SQL

  def up
    DIED_IN_LOC_SUFFIXES.each do |suffix|
      name = "died_in_loc_#{suffix}"
      body = format(DIED_IN_LOC_BODY, temp_outcomes: "temp_patient_outcomes_loc_#{suffix}",
                                       temp_earliest: "temp_earliest_start_date_loc_#{suffix}")
      execute("DROP FUNCTION IF EXISTS #{name}")
      execute("CREATE DEFINER=CURRENT_USER FUNCTION #{name}#{body}")
    end

    execute('DROP FUNCTION IF EXISTS patient_outcome')
    execute("CREATE DEFINER=CURRENT_USER FUNCTION patient_outcome#{PATIENT_OUTCOME_BODY}")

    execute('DROP VIEW IF EXISTS arv_drug')
    execute("CREATE DEFINER=CURRENT_USER SQL SECURITY INVOKER VIEW arv_drug AS #{ARV_DRUG_VIEW}")

    execute('DROP VIEW IF EXISTS clinic_registration_encounter')
    execute("CREATE DEFINER=CURRENT_USER SQL SECURITY DEFINER VIEW clinic_registration_encounter AS #{CLINIC_REGISTRATION_ENCOUNTER_VIEW}")

    execute('DROP VIEW IF EXISTS ever_registered_obs')
    execute("CREATE DEFINER=CURRENT_USER SQL SECURITY DEFINER VIEW ever_registered_obs AS #{EVER_REGISTERED_OBS_VIEW}")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
