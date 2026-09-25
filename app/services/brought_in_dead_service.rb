# frozen_string_literal: true

# Brought-in-dead records for a program: the dashboard card's count, and the
# rows behind the list.
#
# The client used to build the list itself, by pulling every death-outcome
# encounter in the database and rebuilding each row from its observations. On a
# database with 4,407 patient-outcome encounters that was two unfiltered
# encounter requests and thousands of per-encounter follow-ups to display four
# rows, so both the count and the list are answered here with one query instead.
#
# A record is one patient's death on one date, which is how the client keys the
# list (patient + date of death). #count counts distinct pairs rather than
# encounters so that a patient with two death encounters on the same day is one
# record on the card; #list returns a row per encounter and lets the client
# collapse them, which is what it already does when merging offline records in.
class BroughtInDeadService
  # Mirrors DEATH_OUTCOME_ENCOUNTER_TYPES on the client: the current
  # "Patient outcome" type plus the legacy type still present in older data.
  DEATH_OUTCOME_ENCOUNTER_TYPE_IDS = [37, 40].freeze

  DEATH_CONCEPT_NAME = 'Death'
  DATE_OF_DEATH_CONCEPT_NAME = 'Date of death'

  # The remaining columns of the list, named exactly as DEATH_OUTCOME_CONCEPTS
  # names them on the client so both sides read the same observations.
  PLACE_OF_DEATH_CONCEPT_NAME = 'Place of death'
  GUARDIAN_NAME_CONCEPT_NAME = 'Guardian; name and first names'
  CONFIRMED_BY_CONCEPT_NAME = 'Responsible person present'
  DATE_OF_CONFIRMATION_CONCEPT_NAME = 'Date of confinement'

  # Identifier types, not concepts: 28 is the government ID the list shows in
  # its "National ID" column, 3 is the MaHIS record number the client uses to
  # find the patient's CouchDB document.
  MALAWI_NATIONAL_ID_TYPE = 28
  RECORD_IDENTIFIER_TYPE = 3

  # Sites that have not seeded the names above still key their data by these
  # ids, so resolution falls back to them rather than silently counting zero.
  DEATH_CONCEPT_ID_FALLBACKS = [38_748, 11_520].freeze
  DATE_OF_DEATH_CONCEPT_ID_FALLBACKS = [1815, 9794].freeze

  class << self
    # Returns the number of brought-in-dead records visible to the given
    # program and location.
    #
    # program_id  - counts encounters for this program; encounters saved
    #               without a program are always included, matching the client.
    # location_id - defaults to the current user's location. Encounters saved
    #               without a location are always included.
    def count(program_id: nil, location_id: nil)
      death_concept_ids = concept_ids(DEATH_CONCEPT_NAME, DEATH_CONCEPT_ID_FALLBACKS)
      location_id = User.current&.location_id if location_id.blank?

      ActiveRecord::Base.connection.select_value(
        count_sql(death_concept_ids, program_id.presence, location_id.presence)
      ).to_i
    end

    # Returns the brought-in-dead rows the list shows, newest first.
    #
    # Same scoping as #count. Each row carries the columns the table renders
    # plus the identifiers the client needs to open the record: nothing is
    # interpreted here, so a value the client would have read straight off an
    # observation is returned as it was recorded.
    def list(program_id: nil, location_id: nil)
      death_concept_ids = concept_ids(DEATH_CONCEPT_NAME, DEATH_CONCEPT_ID_FALLBACKS)
      location_id = User.current&.location_id if location_id.blank?

      ActiveRecord::Base.connection.select_all(
        list_sql(death_concept_ids, program_id.presence, location_id.presence)
      ).to_a.map { |row| present(row) }
    end

    private

    # A row is ready for the client once its lookup identifiers are gathered and
    # the two fallbacks the client applies are applied: the encounter's provider
    # stands in for an unrecorded person confirming the death, and the encounter
    # time stands in for an unrecorded confirmation date.
    def present(row)
      {
        patient_id: row['patient_id'],
        patient_lookup_ids: [row['record_identifier'], row['patient_id']].compact_blank.map(&:to_s).uniq,
        first_name: row['given_name'],
        surname: row['family_name'],
        birthdate: row['birthdate'],
        national_id: row['national_id'],
        place_of_death: row['place_of_death'],
        date_of_death: row['date_of_death'],
        gender: row['gender'],
        brought_by: row['brought_by'],
        confirmed_by: row['confirmed_by'].presence || row['provider_name'],
        date_of_confirmation: row['date_of_confirmation'].presence || row['recorded_at'],
        recorded_at: row['recorded_at']
      }
    end

    def encounter_conditions(program_id, location_id)
      conditions = ['e.encounter_type IN (:encounter_types)']
      # An encounter with no program belongs to whoever is asking, so it is
      # counted for every program rather than dropped.
      conditions << '(e.program_id IS NULL OR e.program_id <= 0 OR e.program_id = :program_id)' if program_id
      conditions << '(e.location_id IS NULL OR e.location_id = :location_id)' if location_id
      conditions
    end

    # A detail observation of the death, read the way the client reads one:
    # value_text first, then the coded answer's name, then a date, then a
    # number. Details hang off the death observation as its obs group.
    def death_detail(concept_ids_binding)
      <<~SQL.strip
        (SELECT COALESCE(
                  NULLIF(detail.value_text, ''),
                  (SELECT cn.name FROM concept_name cn
                    WHERE cn.concept_id = detail.value_coded AND cn.voided = 0
                    ORDER BY cn.concept_name_id LIMIT 1),
                  DATE_FORMAT(detail.value_datetime, '%Y-%m-%d'),
                  detail.value_numeric)
           FROM obs detail
          WHERE detail.obs_group_id = death.obs_id
            AND detail.voided = 0
            AND detail.concept_id IN (:#{concept_ids_binding})
          ORDER BY detail.obs_id
          LIMIT 1)
      SQL
    end

    def list_sql(death_concept_ids, program_id, location_id)
      conditions = encounter_conditions(program_id, location_id)

      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL,
            SELECT
              e.patient_id,
              e.encounter_datetime AS recorded_at,
              person.birthdate,
              person.gender,
              -- The client reads the first of the patient's names, so take the
              -- earliest one rather than joining and multiplying the row.
              (SELECT pn.given_name FROM person_name pn
                WHERE pn.person_id = e.patient_id AND pn.voided = 0
                ORDER BY pn.person_name_id LIMIT 1) AS given_name,
              (SELECT pn.family_name FROM person_name pn
                WHERE pn.person_id = e.patient_id AND pn.voided = 0
                ORDER BY pn.person_name_id LIMIT 1) AS family_name,
              (SELECT pi.identifier FROM patient_identifier pi
                WHERE pi.patient_id = e.patient_id AND pi.voided = 0
                  AND pi.identifier_type = :national_id_type
                ORDER BY pi.patient_identifier_id DESC LIMIT 1) AS national_id,
              (SELECT pi.identifier FROM patient_identifier pi
                WHERE pi.patient_id = e.patient_id AND pi.voided = 0
                  AND pi.identifier_type = :record_identifier_type
                ORDER BY pi.patient_identifier_id DESC LIMIT 1) AS record_identifier,
              (SELECT CONCAT_WS(' ', pn.given_name, pn.family_name) FROM person_name pn
                WHERE pn.person_id = e.provider_id AND pn.voided = 0
                ORDER BY pn.person_name_id LIMIT 1) AS provider_name,
              #{death_detail('place_of_death_concept_ids')} AS place_of_death,
              #{death_detail('date_of_death_concept_ids')} AS date_of_death,
              #{death_detail('guardian_name_concept_ids')} AS brought_by,
              #{death_detail('confirmed_by_concept_ids')} AS confirmed_by,
              #{death_detail('date_of_confirmation_concept_ids')} AS date_of_confirmation
            FROM (
              -- One death observation per encounter. The client reads the
              -- first one it finds in the encounter's observation tree, so
              -- take the earliest and ignore any duplicates beside it.
              SELECT obs.encounter_id, MIN(obs.obs_id) AS obs_id
                FROM obs
               WHERE obs.voided = 0
                 AND obs.concept_id IN (:death_concept_ids)
               GROUP BY obs.encounter_id
            ) death
            INNER JOIN encounter e ON e.encounter_id = death.encounter_id AND e.voided = 0
            INNER JOIN person ON person.person_id = e.patient_id AND person.voided = 0
            WHERE #{conditions.join("\n              AND ")}
            ORDER BY e.encounter_datetime DESC
          SQL
          {
            encounter_types: DEATH_OUTCOME_ENCOUNTER_TYPE_IDS,
            death_concept_ids:,
            date_of_death_concept_ids: concept_ids(DATE_OF_DEATH_CONCEPT_NAME, DATE_OF_DEATH_CONCEPT_ID_FALLBACKS),
            place_of_death_concept_ids: concept_ids(PLACE_OF_DEATH_CONCEPT_NAME, []),
            guardian_name_concept_ids: concept_ids(GUARDIAN_NAME_CONCEPT_NAME, []),
            confirmed_by_concept_ids: concept_ids(CONFIRMED_BY_CONCEPT_NAME, []),
            date_of_confirmation_concept_ids: concept_ids(DATE_OF_CONFIRMATION_CONCEPT_NAME, []),
            national_id_type: MALAWI_NATIONAL_ID_TYPE,
            record_identifier_type: RECORD_IDENTIFIER_TYPE,
            program_id:,
            location_id:
          }
        ]
      )
    end

    def count_sql(death_concept_ids, program_id, location_id)
      conditions = encounter_conditions(program_id, location_id)

      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL,
            SELECT COUNT(*) FROM (
              SELECT DISTINCT
                e.patient_id,
                (SELECT COALESCE(detail.value_text, DATE_FORMAT(detail.value_datetime, '%Y-%m-%d'), '')
                   FROM obs detail
                  WHERE detail.obs_group_id = death.obs_id
                    AND detail.voided = 0
                    AND detail.concept_id IN (:date_of_death_concept_ids)
                  ORDER BY detail.obs_id
                  LIMIT 1) AS date_of_death
              FROM (
                -- One death observation per encounter. The client reads the
                -- first one it finds in the encounter's observation tree, so
                -- take the earliest and ignore any duplicates beside it.
                SELECT obs.encounter_id, MIN(obs.obs_id) AS obs_id
                  FROM obs
                 WHERE obs.voided = 0
                   AND obs.concept_id IN (:death_concept_ids)
                 GROUP BY obs.encounter_id
              ) death
              INNER JOIN encounter e ON e.encounter_id = death.encounter_id AND e.voided = 0
              WHERE #{conditions.join("\n                AND ")}
            ) brought_in_dead
          SQL
          {
            encounter_types: DEATH_OUTCOME_ENCOUNTER_TYPE_IDS,
            death_concept_ids:,
            date_of_death_concept_ids: concept_ids(DATE_OF_DEATH_CONCEPT_NAME, DATE_OF_DEATH_CONCEPT_ID_FALLBACKS),
            program_id:,
            location_id:
          }
        ]
      )
    end

    # Concepts are resolved by name so each site counts against its own
    # dictionary, the way the client does.
    def concept_ids(name, fallbacks)
      resolved = ConceptName.where(name:, voided: 0).distinct.pluck(:concept_id)
      (resolved + fallbacks).uniq
    end
  end
end
