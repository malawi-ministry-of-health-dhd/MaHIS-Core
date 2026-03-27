# frozen_string_literal: true

module ArtService
  module Reports
    # This class generates the LIMS results report (results delivered electronically)
    class LimsResults
      include CommonSqlQueryUtils
      attr_reader :start_date, :end_date

      def initialize(start_date:, end_date:, **kwargs)
        @start_date = start_date
        @end_date = end_date
        @occupation = kwargs[:occupation]
        @dsd = kwargs[:dsd]
        @location_id = kwargs[:location_id] || Location.current&.id || User.current&.location_id
      end

      def find_report
        data
      end

      private

      def data
        ActiveRecord::Base.connection.select_all <<~SQL
          SELECT o.start_date AS date_ordered, pn.given_name, pn.family_name, pi.identifier AS arv_number, e.patient_id,
          las.date_received, o.accession_number, CONCAT(COALESCE(res.value_modifier, '='), COALESCE(res.value_text, res.value_numeric)) AS result,
          cn.name AS test_name, las.acknowledgement_type AS result_delivery_mode, COALESCE(latest_test_status.value_text, statuses.value_text) AS order_status, reason_test.name AS test_reason
          FROM orders o
          LEFT JOIN lims_acknowledgement_statuses las ON las.order_id = o.order_id
          INNER JOIN encounter e ON e.encounter_id = o.encounter_id AND e.voided = 0 AND (e.program_id IN (#{hiv_program_id}, #{laboratory_program_id}))
          #{dsd_query(dsd: @dsd, model: 'e') if @dsd}
          INNER JOIN users u ON u.user_id = o.orderer
          INNER JOIN person_name pn ON pn.person_id = u.person_id
          INNER JOIN obs test ON test.person_id = e.patient_id AND test.voided = 0 AND test.order_id = o.order_id AND test.concept_id = #{test_type_concept_id}
          INNER JOIN concept_name cn ON cn.concept_id = test.value_coded AND cn.voided = 0 AND cn.locale_preferred = 1
          LEFT JOIN patient_identifier pi ON pi.patient_id = e.patient_id AND pi.voided = 0 AND pi.identifier_type = #{identifier_type}
          LEFT JOIN obs ON obs.person_id = e.patient_id AND obs.voided = 0 AND obs.order_id = o.order_id
            AND obs.concept_id = #{lab_test_result_concept_id}
          LEFT JOIN obs statuses ON statuses.order_id = o.order_id AND statuses.voided = 0 AND statuses.concept_id = #{lab_order_status_concept_id}
          LEFT JOIN obs res ON res.obs_group_id = obs.obs_id AND res.voided = 0 AND res.order_id = o.order_id
          LEFT JOIN obs reason ON reason.order_id = o.order_id AND reason.voided = 0  AND reason.concept_id = #{reason_for_test_concept_id}
          LEFT JOIN concept_name reason_test ON reason_test.concept_id = reason.value_coded AND reason_test.voided = 0
          LEFT JOIN (
            SELECT ts.obs_group_id, ts.value_text, ts.obs_datetime,
                   ROW_NUMBER() OVER (PARTITION BY ts.obs_group_id ORDER BY ts.obs_datetime DESC) AS rn
            FROM obs AS ts
            INNER JOIN concept_name AS cn_ts ON cn_ts.concept_id = ts.concept_id AND cn_ts.name = 'Lab Test Status'
            WHERE ts.voided = 0
          ) AS latest_test_status ON latest_test_status.obs_group_id = test.obs_id AND latest_test_status.rn = 1
          LEFT JOIN (#{current_occupation_query}) AS a ON a.person_id = e.patient_id
          WHERE DATE(o.start_date) BETWEEN '#{start_date}' AND '#{end_date}' AND o.voided = 0
          #{@location_id ? "AND e.location_id = #{ActiveRecord::Base.connection.quote(@location_id)}" : ''}
          #{%w[Military Civilian].include?(@occupation) ? 'AND' : ''} #{occupation_filter(occupation: @occupation, field_name: 'value', table_name: 'a', include_clause: false)}
          AND cn.name = 'HIV viral load' GROUP BY o.order_id
        SQL
      end

      def hiv_program_id
        @hiv_program_id ||= Program.find_by_name('HIV PROGRAM')&.program_id || 1
      end

      def laboratory_program_id
        @laboratory_program_id ||= Program.find_by_name('LABORATORY ORDERS')&.program_id || 23
      end

      def test_type_concept_id
        @test_type_concept_id ||= ConceptName.find_by_name('Test Type')&.concept_id
      end

      def lab_test_result_concept_id
        @lab_test_result_concept_id ||= ConceptName.find_by_name('Lab test result')&.concept_id
      end

      def lab_order_status_concept_id
        @lab_order_status_concept_id ||= ConceptName.find_by_name('Lab order status')&.concept_id
      end

      def reason_for_test_concept_id
        @reason_for_test_concept_id ||= ConceptName.find_by_name('Reason for test')&.concept_id
      end

      def identifier_type
        @identifier_type ||= begin
          filling_number = GlobalPropertyService.use_filing_numbers?
          type_name = filling_number ? 'Filing Number' : 'ARV Number'
          PatientIdentifierType.find_by_name(type_name)&.patient_identifier_type_id
        end
      end
    end
  end
end
