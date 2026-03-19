# frozen_string_literal: true

module ArtService
  module Reports
    # Returns all patients alive and on treatment within a given
    # time period (Tx Curr).
    class PatientsAliveAndOnTreatment
      attr_reader :start_date, :end_date

      include ConcurrencyUtils
      include ArtTempTablesNaming

      def initialize(start_date:, end_date:, outcomes_definition: 'moh', rebuild_outcomes: true, **kwargs)
        @start_date = start_date
        @end_date = end_date
        @rebuild_outcomes = rebuild_outcomes
        @outcomes_definition = outcomes_definition
        @occupation = kwargs[:occupation]
      end

      ##
      # Repopulates temp_patient_outcomes and temp_earliest_start_date tables.
      #
      # The data in temp_patient_outcomes can be used to quickly find patients
      # with various outcomes.
      def refresh_outcomes_table
        logger.debug('Initialising cohort temporary tables...')
        CohortBuilder.new(outcomes_definition: @outcomes_definition)
                     .init_temporary_tables(@start_date, @end_date, @occupation)
      end

      def find_report
        query.map(&:patient_id)
      end

      def query
        lock_file = "art_service/reports/cohort_#{Location.current.location_id}.lock"
        with_lock(lock_file) do
          refresh_outcomes_table if @rebuild_outcomes || !outcomes_table_exists?

          Patient.find_by_sql <<~SQL
            SELECT patient_id FROM #{temp_patient_outcomes} WHERE cum_outcome LIKE 'On antiretrovirals'
          SQL
        end
      end

      private

      def outcomes_table_exists?
        result = ActiveRecord::Base.connection.select_one <<~SQL
          SELECT COUNT(*) AS count
          FROM information_schema.tables
          WHERE table_schema = DATABASE()
          AND table_name = '#{temp_patient_outcomes}'
        SQL
        result['count'].to_i.positive?
      end

      def logger
        Rails.logger
      end
    end
  end
end
