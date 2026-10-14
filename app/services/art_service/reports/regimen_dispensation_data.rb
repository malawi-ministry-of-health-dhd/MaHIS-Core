# frozen_string_literal: true

module ArtService
  module Reports
    # this report is used to generate regimen data
    class RegimenDispensationData
      include CommonSqlQueryUtils
      include ArtTempTablesNaming
      include ModelUtils
      attr_reader :start_date, :end_date, :type

      def initialize(start_date:, end_date:, **kwargs)
        @start_date = ActiveRecord::Base.connection.quote(start_date.to_date.strftime('%Y-%m-%d 00:00:00'))
        @end_date = ActiveRecord::Base.connection.quote(end_date.to_date.strftime('%Y-%m-%d 23:59:59'))
        @type = kwargs[:type]
        @occupation = kwargs[:occupation]
        @dsd = kwargs[:dsd]
        @location_id = kwargs[:location_id] || Location.current&.location_id || User.current&.location&.location_id
        @arv_number_identifier_type_id = patient_identifier_type('ARV Number')&.id || 4
        @hiv_program_id = program('HIV Program')&.program_id || 1
        @on_arv_state_id = program('HIV Program').state('On antiretrovirals').program_workflow_state_id
        @drug_order_type_id = order_type('Drug Order')&.order_type_id || 1
      end

      def find_report
        drop_regimen_data
        create_filtered_data
        process_clients
      end

      private

      # rubocop:disable Metrics/AbcSize
      def drop_regimen_data
        execute_query "DROP TABLE IF EXISTS #{temp_current_dispensation}"
        execute_query "DROP TABLE IF EXISTS #{temp_drug_dispensed}"
        execute_query "DROP TABLE IF EXISTS #{temp_current_regimen_names}"
        execute_query "DROP TABLE IF EXISTS #{temp_current_patient_regimen}"
        execute_query "DROP TABLE IF EXISTS #{temp_reg_outcome}"
        execute_query "DROP TABLE IF EXISTS #{temp_vl_results}"
        execute_query "DROP TABLE IF EXISTS #{temp_current_vl_results}"
        execute_query "DROP TABLE IF EXISTS #{temp_regimen_patient_weight}"
        execute_query "DROP TABLE IF EXISTS #{temp_regimen_data}"
        execute_query "DROP TABLE IF EXISTS #{temp_patient_start_date}"
        execute_query "DROP TABLE IF EXISTS #{temp_vl_result_candidates}"
      end
      # rubocop:enable Metrics/AbcSize

      def create_filtered_data
        create_temp_current_dispensation
        create_temp_drug_dispensed
        create_temp_current_regimen
        create_temp_current_patient_regimen
        create_temp_patient_outcome
        create_temp_vl_result
        create_temp_current_vl_results
        create_temp_regimen_patient_weight
        create_temp_patient_start_date
      end

      def create_temp_current_dispensation
        select_sql = <<~SQL
          SELECT o.patient_id, MAX(o.start_date) AS start_date
          FROM orders o
          INNER JOIN encounter e ON e.encounter_id = o.encounter_id AND e.voided = 0
            #{@location_id ? "AND e.location_id = #{@location_id}" : ''}
          INNER JOIN drug_order od ON od.order_id = o.order_id AND od.quantity > 0 AND od.drug_inventory_id IN (SELECT drug_id FROM arv_drug)
          #{dsd_query(dsd: @dsd, model: 'o') if @dsd}
          LEFT JOIN (#{current_occupation_query}) a ON a.person_id = o.patient_id
          WHERE o.start_date > #{end_date} - INTERVAL 18 MONTH AND o.start_date < #{end_date} + INTERVAL 1 DAY
          AND o.start_date BETWEEN #{@start_date} AND #{@end_date}
          AND o.voided = 0 #{%w[Military Civilian].include?(@occupation) ? 'AND' : ''} #{occupation_filter(occupation: @occupation, field_name: 'value', table_name: 'a', include_clause: false)}
          AND o.order_type_id = #{@drug_order_type_id}
          GROUP BY o.patient_id
        SQL

        create_indexed_temp_table(temp_current_dispensation, idx_current_disp, 'patient_id, start_date', select_sql)
      end

      def create_temp_drug_dispensed
        select_sql = <<~SQL
          SELECT o.patient_id, od.drug_inventory_id, d.name, o.start_date, od.quantity
          FROM orders o
          INNER JOIN encounter e ON e.encounter_id = o.encounter_id AND e.voided = 0
            #{@location_id ? "AND e.location_id = #{@location_id}" : ''}
          #{dsd_query(dsd: @dsd, model: 'o') if @dsd}
          INNER JOIN #{temp_current_dispensation} tcd ON tcd.patient_id = o.patient_id AND tcd.start_date = o.start_date
          INNER JOIN drug_order od ON od.order_id = o.order_id AND od.quantity > 0 AND od.drug_inventory_id IN (SELECT drug_id FROM arv_drug)
          INNER JOIN drug d ON d.drug_id = od.drug_inventory_id AND d.retired  = 0
          WHERE o.voided = 0
          AND o.order_type_id = #{@drug_order_type_id}
        SQL

        create_indexed_temp_table(temp_drug_dispensed, idx_drug_disp, 'patient_id, start_date', select_sql)
      end

      def create_temp_current_regimen
        select_sql = <<~SQL
          SELECT GROUP_CONCAT(drug.drug_id ORDER BY drug.drug_id ASC) AS drugs, regimen_name.name AS name
          FROM moh_regimen_combination AS combo
          INNER JOIN moh_regimen_combination_drug AS drug USING (regimen_combination_id)
          INNER JOIN moh_regimen_name AS regimen_name USING (regimen_name_id)
          GROUP BY combo.regimen_combination_id
        SQL

        create_indexed_temp_table(temp_current_regimen_names, idx_regimen_names, 'drugs(50)', select_sql)
      end

      def create_temp_current_patient_regimen
        select_sql = <<~SQL
          SELECT d.patient_id, name
          FROM #{temp_current_regimen_names} tcrn
          INNER JOIN (
            SELECT patient_id, GROUP_CONCAT(drug_inventory_id ORDER BY drug_inventory_id ASC) AS drugs
            FROM #{temp_drug_dispensed}
            GROUP BY patient_id
          ) d ON d.drugs = tcrn.drugs
          #{dsd_query(dsd: @dsd, model: 'd') if @dsd}
        SQL

        create_indexed_temp_table(temp_current_patient_regimen, idx_patient_regimen, 'patient_id', select_sql)
      end

      def create_temp_patient_outcome
        select_sql = <<~SQL
          SELECT temp_current_dispensation.patient_id, #{@type == 'pepfar' ? "pepfar_patient_outcome(temp_current_dispensation.patient_id, #{@end_date})" : "patient_outcome(temp_current_dispensation.patient_id, #{@end_date})"} outcome
          FROM #{temp_current_dispensation} AS temp_current_dispensation
          #{dsd_query(dsd: @dsd, model: 'temp_current_dispensation') if @dsd}
        SQL

        create_indexed_temp_table(temp_reg_outcome, idx_reg_outcome, 'patient_id', select_sql)
      end

      def create_temp_vl_result
        create_temp_vl_result_candidates

        select_sql = <<~SQL
          SELECT candidate.result_date, candidate.result, candidate.patient_id
          FROM #{temp_vl_result_candidates} AS candidate
          INNER JOIN (
            SELECT concept_id, name
            FROM concept_name
            INNER JOIN concept USING (concept_id)
            WHERE concept.retired = 0
            AND name NOT LIKE 'Lab test result'
            GROUP BY concept_id
          ) AS measure_concept ON measure_concept.concept_id = candidate.concept_id
        SQL

        create_indexed_temp_table(temp_vl_results, idx_vl_result, 'patient_id, result_date', select_sql)
      end

      def create_temp_vl_result_candidates
        select_sql = <<~SQL
          SELECT
            lab_result_obs.obs_datetime AS result_date,
            CONCAT (COALESCE(measure.value_modifier, '='),' ',COALESCE(measure.value_numeric, measure.value_text, '')) AS result,
            lab_result_obs.person_id AS patient_id,
            measure.concept_id
          FROM (
            SELECT DISTINCT patient_id
            FROM #{temp_reg_outcome}
            WHERE outcome = 'On antiretrovirals'
          ) AS on_treatment
          INNER JOIN obs AS measure ON measure.person_id = on_treatment.patient_id
            AND measure.voided = 0
            AND measure.obs_group_id IS NOT NULL
            AND (measure.value_numeric IS NOT NULL || measure.value_text IS NOT NULL)
          INNER JOIN obs AS lab_result_obs ON lab_result_obs.obs_id = measure.obs_group_id
            AND lab_result_obs.voided = 0
            AND lab_result_obs.obs_datetime < #{end_date} + INTERVAL 1 DAY
          INNER JOIN orders ON orders.order_id = lab_result_obs.order_id AND orders.voided = 0
          INNER JOIN encounter e ON e.encounter_id = orders.encounter_id AND e.voided = 0
            #{@location_id ? "AND e.location_id = #{@location_id}" : ''}
          #{dsd_query(dsd: @dsd, model: 'orders') if @dsd}
        SQL

        create_indexed_temp_table(temp_vl_result_candidates, idx_vl_result_candidates, 'concept_id', select_sql)
      end

      def create_temp_current_vl_results
        select_sql = <<~SQL
          SELECT t.*
          FROM #{temp_vl_results} t
          LEFT JOIN #{temp_vl_results} td ON td.patient_id = t.patient_id AND td.result_date > t.result_date
          #{dsd_query(dsd: @dsd, model: 't') if @dsd}
          WHERE td.patient_id IS NULL
        SQL

        create_indexed_temp_table(temp_current_vl_results, idx_current_vl, 'patient_id', select_sql)
      end

      def create_temp_regimen_patient_weight
        weight_concept_id = concept_name_to_id('Weight (kg)')
        raise ActiveRecord::RecordNotFound, "Concept 'Weight (kg)' was not found" unless weight_concept_id

        select_sql = <<~SQL
          SELECT tro.patient_id, o.value_numeric AS weight
          FROM #{temp_reg_outcome} tro
          INNER JOIN (
            SELECT person_id, MAX(obs_datetime) AS max_datetime
            FROM obs
            WHERE concept_id = #{weight_concept_id} AND voided = 0 AND obs_datetime < #{end_date} + INTERVAL 1 DAY
            GROUP BY person_id
          ) latest_obs ON latest_obs.person_id = tro.patient_id
           #{dsd_query(dsd: @dsd, model: 'tro') if @dsd}
          INNER JOIN obs o ON o.person_id = latest_obs.person_id AND o.concept_id = #{weight_concept_id} AND o.obs_datetime = latest_obs.max_datetime AND o.voided = 0 AND o.obs_datetime < #{end_date} + INTERVAL 1 DAY
          WHERE tro.outcome = 'On antiretrovirals'
        SQL

        create_indexed_temp_table(temp_regimen_patient_weight, idx_patient_weight, 'patient_id', select_sql)
      end

      def create_temp_patient_start_date
        select_sql = <<~SQL
          SELECT p.patient_id,
                 date_antiretrovirals_started(p.patient_id, MIN(s.start_date)) AS earliest_start_date
          FROM patient_program p
          INNER JOIN patient_state s ON s.patient_program_id = p.patient_program_id
          #{dsd_query(dsd: @dsd, model: 'p') if @dsd}
          WHERE p.voided = 0
            AND s.voided = 0
            AND p.program_id = #{@hiv_program_id}
            AND s.state = #{@on_arv_state_id}
            AND s.start_date < #{end_date} + INTERVAL 1 DAY
            AND p.patient_id IN (SELECT patient_id FROM #{temp_reg_outcome} WHERE outcome = 'On antiretrovirals')
          GROUP BY p.patient_id
        SQL

        create_indexed_temp_table(temp_patient_start_date, idx_start_date, 'patient_id', select_sql)
      end

      def create_indexed_temp_table(table_name, index_name, index_columns, select_sql)
        connection = ActiveRecord::Base.connection
        connection.execute "CREATE TABLE #{table_name} #{select_sql}"
        connection.execute "CREATE INDEX #{index_name} ON #{table_name} (#{index_columns})"
      end

      def temp_vl_result_candidates
        temp_table_name('temp_vl_result_candidates')
      end

      def idx_vl_result_candidates
        temp_index_name('idx_vl_result_candidates')
      end

      def clients_alive_on_treatment
        result = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT
            trc.patient_id,
            p.gender,
            p.birthdate,
            pn.given_name,
            pn.family_name,
            i.identifier arv_number,
            tpw.weight,
            tcvr.result_date,
            tcvr.result,
            tcp.name regimen,
            trc.earliest_start_date
          FROM #{temp_patient_start_date} trc
          INNER JOIN #{temp_current_dispensation} tcd ON tcd.patient_id = trc.patient_id AND tcd.start_date BETWEEN #{@start_date} AND #{@end_date}
          #{dsd_query(dsd: @dsd, model: 'trc') if @dsd}
          INNER JOIN person p ON p.person_id = trc.patient_id AND p.voided = 0
          INNER JOIN person_name pn ON pn.person_id = p.person_id AND pn.voided = 0
          LEFT JOIN patient_identifier i ON i.patient_id = p.person_id AND i.identifier_type = #{@arv_number_identifier_type_id} AND i.voided = 0
          LEFT JOIN #{temp_regimen_patient_weight} tpw ON tpw.patient_id = trc.patient_id
          LEFT JOIN #{temp_current_vl_results} tcvr ON tcvr.patient_id = trc.patient_id
          LEFT JOIN #{temp_current_patient_regimen} tcp ON tcp.patient_id = trc.patient_id
          GROUP BY trc.patient_id
        SQL

        Rails.logger.info "clients_alive_on_treatment returned #{result.count} patients"
        result
      end

      def alive_clients
        clients = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT trc.patient_id
          FROM #{temp_reg_outcome} trc
          INNER JOIN person p ON p.person_id = trc.patient_id AND p.voided = 0
          where trc.outcome = 'On antiretrovirals' AND LEFT(p.gender, 1) = 'F'
        SQL
        clients.map { |client| client['patient_id'] }
      end

      def process_clients
        clients = {}
        @maternal_status = maternal_status
        clients_alive = clients_alive_on_treatment
        medications_by_patient = fetch_medications(clients_alive.map { |client| client['patient_id'] })

        clients_alive.each do |client|
          patient_id = client['patient_id']
          clients[client['patient_id']] = {
            arv_number: client['arv_number'],
            given_name: client['given_name'],
            family_name: client['family_name'],
            birthdate: client['birthdate'],
            gender: client['gender'] == 'M' ? 'M' : fetch_maternal_status(patient_id),
            current_regimen: client['regimen'],
            current_weight: client['weight'],
            art_start_date: client['earliest_start_date'],
            medication: medications_by_patient.fetch(patient_id.to_i, []),
            vl_result: client['result'],
            vl_result_date: client['result_date']
          }
        end
        clients
      end

      def maternal_status
        ArtService::Reports::Pepfar::ViralLoadCoverage2.new(start_date: @start_date,
                                                            end_date: @end_date).vl_maternal_status(alive_clients)
      end

      def fetch_maternal_status(patient_id)
        return nil if patient_id.blank?

        gender = 'FNP'
        gender = 'FP' if @maternal_status[:FP].include?(patient_id)
        gender = 'FBf' if @maternal_status[:FBf].include?(patient_id)
        gender
      end

      def fetch_medications(patient_ids)
        patient_ids = patient_ids.map(&:to_i).uniq
        return {} if patient_ids.empty?

        data = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT tdd.patient_id, tdd.name, DATE(tdd.start_date) start_date, tdd.quantity
          FROM #{temp_drug_dispensed} tdd
          WHERE tdd.patient_id IN (#{patient_ids.join(',')})
        SQL

        data.group_by { |row| row['patient_id'].to_i }.transform_values do |rows|
          rows.map do |row|
            { medication: row['name'], start_date: row['start_date'], quantity: row['quantity'] }
          end
        end
      end

      def execute_query(query)
        ActiveRecord::Base.connection.execute(query)
      end
    end
  end
end
