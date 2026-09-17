# frozen_string_literal: true

# Counts brought-in-dead records for a program's dashboard card.
#
# The client already builds the brought-in-dead *list* itself, by pulling every
# death-outcome encounter and rebuilding each row from its observations. That is
# far too much work just to print a number on a card, so this service answers
# the count with a single query.
#
# A record is one patient's death on one date, which is how the client keys the
# list (patient + date of death). Counting distinct pairs rather than encounters
# keeps this in step with the list when a patient has more than one death
# encounter recorded on the same day.
class BroughtInDeadService
  # Mirrors DEATH_OUTCOME_ENCOUNTER_TYPES on the client: the current
  # "Patient outcome" type plus the legacy type still present in older data.
  DEATH_OUTCOME_ENCOUNTER_TYPE_IDS = [37, 40].freeze

  DEATH_CONCEPT_NAME = 'Death'
  DATE_OF_DEATH_CONCEPT_NAME = 'Date of death'

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

    private

    def count_sql(death_concept_ids, program_id, location_id)
      conditions = ['e.encounter_type IN (:encounter_types)']
      # An encounter with no program belongs to whoever is asking, so it is
      # counted for every program rather than dropped.
      conditions << '(e.program_id IS NULL OR e.program_id <= 0 OR e.program_id = :program_id)' if program_id
      conditions << '(e.location_id IS NULL OR e.location_id = :location_id)' if location_id

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
