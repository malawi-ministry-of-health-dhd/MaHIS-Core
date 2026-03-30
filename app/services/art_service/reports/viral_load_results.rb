# frozen_string_literal: true

module ArtService
  module Reports
    ##
    # Pulls patient's whose most recent viral load result in selected reporting period
    # is in specified viral load classification.
    #
    # Classification are passed as parameter range and are limited to the following
    # values:
    #   - suppressed
    #   - low-level-viraemia
    #   - viraemia-1000
    #
    # The classifications above follow the ART guidelines 2018 Addendum.
    class ViralLoadResults
      include CommonSqlQueryUtils

      # Specimen type constants
      PLASMA_BLOOD_SPECIMENS = ['Blood', 'Venous Whole Blood', 'Plasma'].freeze
      DBS_SPECIMENS = ['DBS (Free drop to DBS card)', 'DBS (Using capillary tube)'].freeze
      ALL_SPECIMENS = (PLASMA_BLOOD_SPECIMENS + DBS_SPECIMENS).freeze

      def initialize(start_date:, end_date: nil, range: nil, **kwargs)
        @start_date = start_date
        @end_date = end_date
        @range = range || 'viraemia-1000+'
        @occupation = kwargs[:occupation]
        @dsd = kwargs[:dsd]
        @location_id = kwargs[:location_id] || Location.current&.location_id || User.current&.location_id
      end

      def find_report
        start_date = ActiveRecord::Base.connection.quote(@start_date)
        end_date = ActiveRecord::Base.connection.quote(@end_date)

        ActiveRecord::Base.connection.select_all <<~SQL
          SELECT orders.patient_id,
                 patient_identifier.identifier AS arv_number,
                 person.birthdate AS birthdate,
                 disaggregated_age_group(person.birthdate, #{end_date}) AS age_group,
                 person.gender AS gender,
                 orders.start_date AS order_date,
                 specimen_type.name AS specimen,
                 COALESCE(orders.discontinued_date, orders.start_date) AS specimen_drawn_date,
                 test_results_obs.obs_datetime AS result_date,
                 COALESCE(test_result_measure_obs.value_modifier, '=') AS result_modifier,
                 COALESCE(test_result_measure_obs.value_numeric, test_result_measure_obs.value_text) AS result,
                 patient_current_regimen(orders.patient_id, orders.start_date) AS current_regimen
          FROM orders
          INNER JOIN concept_name AS specimen_type
            ON specimen_type.concept_id = orders.concept_id
            AND #{specimen_in_condition(ALL_SPECIMENS)}
            AND specimen_type.voided = 0
          LEFT JOIN patient_identifier
            ON patient_identifier.patient_id = orders.patient_id
            AND patient_identifier.voided = 0
            AND patient_identifier.identifier_type IN (
              SELECT patient_identifier_type_id FROM patient_identifier_type WHERE name = 'ARV Number' AND retired = 0
            )
          INNER JOIN person
            ON person.person_id = orders.patient_id
            AND person.voided = 0
          #{dsd_query(dsd: @dsd, model: 'orders') if @dsd}
          LEFT JOIN (#{current_occupation_query}) AS a ON a.person_id = orders.patient_id
          /* For each lab order find an HIV Viral Load test */
          INNER JOIN obs AS test_obs
            ON test_obs.order_id = orders.order_id
            AND test_obs.concept_id IN #{concept_id_subquery('Test type')}
            AND test_obs.value_coded IN #{concept_id_subquery('HIV Viral load')}
            AND test_obs.voided = 0
            #{@location_id ? "AND test_obs.location_id = #{ActiveRecord::Base.connection.quote(@location_id)}" : ''}
          /* Select each test's results */
          INNER JOIN obs AS test_results_obs
            ON test_results_obs.obs_group_id = test_obs.obs_id
            AND test_results_obs.concept_id IN #{concept_id_subquery('Lab test result')}
            AND test_results_obs.voided = 0
            #{@location_id ? "AND test_results_obs.location_id = #{ActiveRecord::Base.connection.quote(@location_id)}" : ''}
            AND test_results_obs.obs_datetime >= DATE(#{start_date})
            AND test_results_obs.obs_datetime < DATE(#{end_date}) + INTERVAL 1 DAY
          /* Limit the test result's to each patient's most recent result. */
          INNER JOIN (
            SELECT MAX(obs_datetime) AS obs_datetime,
                   person_id
            FROM obs
            INNER JOIN orders
              ON orders.order_id = obs.order_id
              AND #{lab_order_type_condition}
              AND orders.concept_id IN (
                SELECT concept_id FROM concept_name INNER JOIN concept USING (concept_id)
                WHERE concept_name.name IN (#{ALL_SPECIMENS.map { |s| ActiveRecord::Base.connection.quote(s) }.join(', ')})
                  AND concept.retired = 0 AND concept_name.voided = 0
              )
              AND orders.voided = 0
            WHERE obs.concept_id IN #{concept_id_subquery('Lab test result')}
              AND obs.voided = 0
              #{@location_id ? "AND obs.location_id = #{ActiveRecord::Base.connection.quote(@location_id)}" : ''}
              AND obs.obs_datetime >= DATE(#{start_date})
              AND obs.obs_datetime < DATE(#{end_date}) + INTERVAL 1 DAY
            GROUP BY person_id
          ) AS max_test_results
            ON max_test_results.obs_datetime = test_results_obs.obs_datetime
            AND max_test_results.person_id = test_results_obs.person_id
          /* Find a viral load measure that can be classified as High on the test results */
          INNER JOIN obs AS test_result_measure_obs
            ON test_result_measure_obs.obs_group_id = test_results_obs.obs_id
            AND test_result_measure_obs.concept_id IN #{concept_id_subquery('HIV Viral load')}
            AND (test_result_measure_obs.value_numeric IS NOT NULL
                 OR test_result_measure_obs.value_text IS NOT NULL)
            AND test_result_measure_obs.voided = 0
            AND (#{query_range})
          WHERE #{lab_order_type_condition}
            AND orders.voided = 0
            #{%w[Military Civilian].include?(@occupation) ? 'AND' : ''} #{occupation_filter(occupation: @occupation, field_name: 'value', table_name: 'a', include_clause: false)}
          GROUP BY orders.patient_id
        SQL
      end

      def specimen_types
        Concept.joins(:concept_names)
               .merge(ConceptName.where(name: ALL_SPECIMENS))
               .select(:concept_id)
               .to_sql
      end

      # Helper method to generate SQL IN clause for specimen types
      def specimen_in_condition(specimens, field_name = 'specimen_type.name')
        quoted_specimens = specimens.map { |s| ActiveRecord::Base.connection.quote(s) }.join(', ')
        "#{field_name} IN (#{quoted_specimens})"
      end

      # Helper method for laboratory order type condition
      def lab_order_type_condition(field_name = 'orders.order_type_id')
        "#{field_name} IN (SELECT order_type_id FROM order_type WHERE (name = 'Laboratory order' OR name = 'Lab') AND retired = 0)"
      end

      # Helper method to get concept_id for a concept name
      def concept_id_subquery(concept_name)
        quoted_name = ActiveRecord::Base.connection.quote(concept_name)
        "(SELECT concept_id FROM concept_name INNER JOIN concept USING (concept_id) WHERE concept_name.name = #{quoted_name} AND concept.retired = 0 AND concept_name.voided = 0)"
      end

      def dbs_query_range
        case @range.downcase
        when 'suppressed' then <<~SQL

        SQL
        when 'low-level-viremia' then <<~SQL

        SQL
        when 'viraemia-1000+' then <<~SQL
          (test_result_measure_obs.value_numeric >= 1000)
        SQL
        else
          raise InvalidParameterError, "Invalid viral load range: #{@range}"
        end
      end

      def query_range
        case @range.downcase
        when 'suppressed' then <<~SQL
          (/* Plasma/Blood */
           (#{specimen_in_condition(PLASMA_BLOOD_SPECIMENS)}
            AND ((test_result_measure_obs.value_modifier IN ('<', '=') AND test_result_measure_obs.value_text = 'LDL')
                 OR (test_result_measure_obs.value_modifier = '<' AND test_result_measure_obs.value_numeric IN (20, 40, 150)))
                 OR (test_result_measure_obs.value_numeric >= 20 AND test_result_measure_obs.value_numeric < 200))
          /* DBS */
          OR (#{specimen_in_condition(DBS_SPECIMENS)}
              AND (test_result_measure_obs.value_modifier IN ('<', '=') AND test_result_measure_obs.value_text = 'LDL')))
        SQL
        when 'low-level-viraemia' then <<~SQL
          (/* Plasma/Blood */
           (#{specimen_in_condition(PLASMA_BLOOD_SPECIMENS)}
            AND (test_result_measure_obs.value_numeric >= 200 AND test_result_measure_obs.value_numeric < 1000))
           /* DBS */
           OR (#{specimen_in_condition(DBS_SPECIMENS)}
               AND (test_result_measure_obs.value_modifier = '<' AND test_result_measure_obs.value_numeric IN (400, 550, 839))
               OR (test_result_measure_obs.value_numeric >= 400 AND test_result_measure_obs.value_numeric < 1000)))
        SQL
        when 'viraemia-1000' then <<~SQL
          (test_result_measure_obs.value_numeric >= 1000)
        SQL
        else
          raise InvalidParameterError, "Invalid viral load range: #{@range}"
        end
      end
    end
  end
end
