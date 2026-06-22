# frozen_string_literal: true

class CreateReportingPatientArtFacts < ActiveRecord::Migration[8.1]
  def up
    create_table :reporting_patient_art_facts, id: :bigint, if_not_exists: true do |table|
      table.integer :patient_id, null: false
      table.integer :location_id, null: false, default: 0
      table.date :program_state_start_date
      table.date :date_enrolled
      table.date :recorded_start_date
      table.date :estimated_start_date
      table.date :dispensation_start_date
      table.date :earliest_start_date
      table.timestamps null: false
    end

    add_index :reporting_patient_art_facts, %i[location_id patient_id],
              unique: true, name: 'idx_reporting_art_location_patient', if_not_exists: true
    add_index :reporting_patient_art_facts, :patient_id,
              name: 'idx_reporting_art_patient', if_not_exists: true
    add_index :reporting_patient_art_facts, %i[location_id earliest_start_date],
              name: 'idx_reporting_art_location_start', if_not_exists: true

    create_tidb_views if tidb?
  end

  def down
    drop_tidb_views if tidb?
    drop_table :reporting_patient_art_facts, if_exists: true
  end

  private

  def tidb?
    connection.select_value('SELECT VERSION()').to_s.match?(/tidb/i)
  end

  def create_tidb_views
    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW all_person_addresses AS
      SELECT address.person_address_id,
             address.person_id,
             address.preferred,
             address.address1,
             address.address2,
             address.city_village,
             address.state_province,
             address.postal_code,
             address.country,
             address.latitude,
             address.longitude,
             address.creator,
             address.date_created,
             address.voided,
             address.voided_by,
             address.date_voided,
             address.void_reason,
             address.county_district,
             address.neighborhood_cell,
             address.region,
             address.subregion,
             address.township_division,
             address.uuid
      FROM person_address address
      INNER JOIN (
        SELECT person_id, MAX(person_address_id) AS person_address_id
        FROM person_address
        WHERE voided = 0
          AND person_id IS NOT NULL
        GROUP BY person_id
      ) latest ON latest.person_address_id = address.person_address_id
      WHERE address.voided = 0
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW earliest_start_date AS
      SELECT facts.patient_id,
             person.gender,
             person.birthdate,
             MIN(facts.earliest_start_date) AS earliest_start_date,
             MIN(facts.date_enrolled) AS date_enrolled,
             person.death_date,
             TIMESTAMPDIFF(YEAR, person.birthdate, MIN(facts.program_state_start_date)) AS age_at_initiation,
             TIMESTAMPDIFF(DAY, person.birthdate, MIN(facts.program_state_start_date)) AS age_in_days
      FROM reporting_patient_art_facts facts
      INNER JOIN person ON person.person_id = facts.patient_id
      GROUP BY facts.patient_id, person.gender, person.birthdate, person.death_date
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW patients_on_arvs AS
      SELECT patient_id,
             birthdate,
             earliest_start_date,
             death_date,
             gender,
             (TO_DAYS(earliest_start_date) - TO_DAYS(birthdate)) / 365.25 AS age_at_initiation,
             age_in_days
      FROM earliest_start_date
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW guardians AS
      SELECT relationship.person_a AS patient_id,
             relationship.person_b AS guardian_id,
             person.gender,
             person_name.given_name,
             person_name.family_name,
             person_name.middle_name,
             person.birthdate_estimated,
             person.birthdate,
             addresses.address2 AS home_district,
             addresses.state_province AS current_district,
             addresses.address1 AS landmark,
             addresses.city_village AS current_residence,
             addresses.county_district AS traditional_authority
      FROM relationship
      INNER JOIN person_name ON person_name.person_id = relationship.person_b
      LEFT JOIN all_person_addresses addresses ON addresses.person_id = person_name.person_id
      INNER JOIN person ON person.person_id = person_name.person_id
      WHERE relationship.voided = 0
        AND person_name.voided = 0
        AND relationship.person_a IN (SELECT patient_id FROM earliest_start_date)
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW patients_demographics AS
      SELECT earliest.patient_id,
             person_name.given_name,
             person_name.family_name,
             person_name.middle_name,
             person.gender,
             person.birthdate_estimated,
             person.birthdate,
             addresses.address2 AS home_district,
             addresses.state_province AS current_district,
             addresses.address1 AS landmark,
             addresses.city_village AS current_residence,
             addresses.county_district AS traditional_authority,
             earliest.date_enrolled,
             earliest.earliest_start_date,
             earliest.death_date,
             earliest.age_at_initiation,
             earliest.age_in_days
      FROM earliest_start_date earliest
      INNER JOIN person_name ON person_name.person_id = earliest.patient_id AND person_name.voided = 0
      LEFT JOIN all_person_addresses addresses ON addresses.person_id = person_name.person_id AND addresses.voided = 0
      INNER JOIN person ON person.person_id = person_name.person_id AND person.voided = 0
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW patients_with_has_transfer_letter_yes AS
      SELECT obs.person_id,
             person.gender,
             obs.obs_datetime,
             obs.date_created,
             earliest.earliest_start_date
      FROM obs
      INNER JOIN person ON person.person_id = obs.person_id AND person.voided = 0
      INNER JOIN earliest_start_date earliest ON earliest.patient_id = obs.person_id
      WHERE obs.concept_id = 6393
        AND obs.value_coded = 1065
        AND obs.voided = 0
    SQL

    execute <<~SQL
      CREATE OR REPLACE SQL SECURITY INVOKER VIEW reason_for_eligibility_obs AS
      SELECT earliest.patient_id,
             concept_name.name AS reason_for_eligibility,
             obs.obs_datetime,
             earliest.earliest_start_date,
             earliest.date_enrolled
      FROM earliest_start_date earliest
      LEFT JOIN obs ON obs.person_id = earliest.patient_id AND obs.concept_id = 7563 AND obs.voided = 0
      LEFT JOIN concept_name
        ON concept_name.concept_id = obs.value_coded
       AND concept_name.concept_name_type = 'FULLY_SPECIFIED'
       AND concept_name.voided = 0
    SQL
  end

  def drop_tidb_views
    %w[
      reason_for_eligibility_obs
      patients_with_has_transfer_letter_yes
      patients_demographics
      guardians
      patients_on_arvs
      earliest_start_date
    ].each { |view| execute("DROP VIEW IF EXISTS #{view}") }
  end
end
