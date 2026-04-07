# frozen_string_literal: true

module ArtService
  module Reports
    class CohortDisaggregated
      include ArtTempTablesNaming

      COHORT_REGIMENS = %w[
        4A 5A 6A 7A 8A 9A 10A 11A 12A 13A 14A 15A 16A 17A
        0P 2P 4PP 4PA 9PP 9PA 11PP 11PA 12PP 12PA 14PP 14PA 15P 15PP 15PA 16P 17PP 17PA
      ].freeze

      AGE_GROUPS = [
        '<1 year', '1-4 years', '5-9 years', '10-14 years', '15-19 years',
        '20-24 years', '25-29 years', '30-34 years', '35-39 years', '40-44 years',
        '45-49 years', '50-54 years', '55-59 years', '60-64 years', '65-69 years',
        '70-74 years', '75-79 years', '80-84 years', '85-89 years', '90 plus years'
      ].freeze

      def initialize(name:, type:, start_date:, end_date:, rebuild: false, **kwargs)
        @name = name
        @type = type
        @start_date = start_date.to_date
        @end_date = end_date.to_date
        @rebuild = rebuild.to_s.casecmp?('true')
        @occupation = kwargs[:occupation]
        @definition = kwargs[:definition]&.to_s&.downcase || 'moh'
      end

      def find_report
        build_report
      end

      def build_report
        prepare_temp_tables

        rows = []

        AGE_GROUPS.each do |age_group|
          %w[M F].each do |gender|
            rows << build_row(age_group, gender)
          end
        end

        # Male total (all ages)
        rows << build_male_total_row

        # Female sub-groups (all ages)
        %w[FP FNP FBf].each do |gender|
          rows << build_maternal_row(gender)
        end

        rows
      end

      private

      def prepare_temp_tables
        cohort_builder = CohortBuilder.new(outcomes_definition: @definition)
        cohort_builder.init_temporary_tables(@start_date, @end_date, @occupation)
        create_mysql_female_maternal_status
        populate_maternal_status
      end

      def build_row(age_group, gender)
        patients = patients_on_art_for(age_group, gender)
        regimen_distribution = regimen_counts(patients, age_group, gender)
        total = patients
        unknown = regimen_distribution.delete('N/A') || []

        row = { age_group: age_group, gender: gender }
        row[:tx_curr] = total
        COHORT_REGIMENS.each { |r| row[r] = regimen_distribution[r] || [] }
        row[:unknown] = unknown
        row[:total] = total
        row
      end

      def build_male_total_row
        patients = all_male_patients_on_art
        regimen_distribution = regimen_counts(patients, 'All', 'M')
        unknown = regimen_distribution.delete('N/A') || []

        row = { age_group: 'All', gender: 'M' }
        row[:tx_curr] = patients
        COHORT_REGIMENS.each { |r| row[r] = regimen_distribution[r] || [] }
        row[:unknown] = unknown
        row[:total] = patients
        row
      end

      def build_maternal_row(gender)
        patients = maternal_patients_on_art(gender)
        regimen_distribution = regimen_counts(patients, 'All', gender)
        unknown = regimen_distribution.delete('N/A') || []

        row = { age_group: 'All', gender: gender }
        row[:tx_curr] = patients
        COHORT_REGIMENS.each { |r| row[r] = regimen_distribution[r] || [] }
        row[:unknown] = unknown
        row[:total] = patients
        row
      end

      def outcome_column
        @definition == 'pepfar' ? 'pepfar_cum_outcome' : 'moh_cum_outcome'
      end

      def patients_on_art_for(age_group, gender)
        results = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT e.patient_id,
                 disaggregated_age_group(DATE(e.birthdate), DATE('#{@end_date}')) AS age_group
          FROM #{temp_earliest_start_date} e
          INNER JOIN #{temp_patient_outcomes} o ON o.patient_id = e.patient_id
          WHERE LEFT(e.gender, 1) = '#{gender}'
            AND o.#{outcome_column} = 'On antiretrovirals'
          GROUP BY e.patient_id
          HAVING age_group = '#{age_group}';
        SQL
        results.map { |r| r['patient_id'].to_i }
      end

      def all_male_patients_on_art
        results = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT e.patient_id
          FROM #{temp_earliest_start_date} e
          INNER JOIN #{temp_patient_outcomes} o ON o.patient_id = e.patient_id
          WHERE LEFT(e.gender, 1) = 'M'
            AND o.#{outcome_column} = 'On antiretrovirals'
          GROUP BY e.patient_id;
        SQL
        results.map { |r| r['patient_id'].to_i }
      end

      def maternal_patients_on_art(gender)
        results = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT d.patient_id
          FROM temp_disaggregated d
          INNER JOIN #{temp_patient_outcomes} o ON o.patient_id = d.patient_id
          WHERE d.maternal_status = '#{gender}'
            AND o.#{outcome_column} = 'On antiretrovirals';
        SQL
        results.map { |r| r['patient_id'].to_i }
      end

      def regimen_counts(patient_ids, _age_group, _gender)
        return {} if patient_ids.blank?

        distribution = {}
        patient_ids.each do |patient_id|
          regimen_data = ActiveRecord::Base.connection.select_one <<~SQL
            SELECT patient_current_regimen(#{patient_id}, DATE('#{@end_date}')) AS regimen;
          SQL
          regimen = regimen_data['regimen'].to_s
          regimen = COHORT_REGIMENS.include?(regimen) ? regimen : 'N/A'
          distribution[regimen] ||= []
          distribution[regimen] << patient_id
        end
        distribution
      end

      def populate_maternal_status
        initialize_disaggregated

        # temp_maternal_status is already populated by MaternalStatus#process_data
        # (called inside CohortBuilder#update_cum_outcome). Use it directly.
        ActiveRecord::Base.connection.execute <<~SQL
          INSERT INTO temp_disaggregated (patient_id, maternal_status, initial_maternal_status, age_group)
          SELECT e.patient_id,
            COALESCE(m.maternal_status, 'FNP') AS maternal_status,
            COALESCE(m.maternal_status, 'FNP') AS initial_maternal_status,
            'All' AS age_group
          FROM #{temp_earliest_start_date} e
          INNER JOIN #{temp_patient_outcomes} o ON o.patient_id = e.patient_id
          LEFT JOIN #{temp_maternal_status} m ON m.patient_id = e.patient_id
          WHERE LEFT(e.gender, 1) = 'F'
            AND o.#{outcome_column} = 'On antiretrovirals'
          ON DUPLICATE KEY UPDATE
            maternal_status = VALUES(maternal_status),
            initial_maternal_status = VALUES(initial_maternal_status);
        SQL
      end

      public

      def initialize_disaggregated
        ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS temp_disaggregated')

        ActiveRecord::Base.connection.execute(
          'CREATE TABLE IF NOT EXISTS temp_disaggregated (
             patient_id INTEGER PRIMARY KEY,
             age_group VARCHAR(20),
             initial_maternal_status VARCHAR(10),
             maternal_status VARCHAR(10),
             given_ipt INT(1),
             screened_for_tb INT(1)
          );'
        )

        { temp_disaggregated: 'created' }
      end

      def disaggregated(quarter, age_group)
        if quarter == 'pepfar'
          start_date = @start_date
          end_date = @end_date

          begin
            records = ActiveRecord::Base.connection.select_one("SELECT count(*) rec_count FROM #{temp_patient_outcomes};")
            @rebuild = true if records['rec_count'].to_i < 1
          rescue StandardError
            initialize_disaggregated
            rebuild_outcomes 'pepfar'
          end

          if @rebuild
            initialize_disaggregated
            rebuild_outcomes 'pepfar'
          end

        else
          start_date, end_date = generate_start_date_and_end_date(quarter)

          if @rebuild
            initialize_disaggregated
            art_service = ArtService::Reports::CohortBuilder.new
            art_service.init_temporary_tables(@start_date, @end_date, @occupation)
            art_service.update_tb_status(end_date)
          end
        end

        tmp = get_age_groups(age_group, start_date, end_date)

        # A hack to get female that were pregnant / breastfeeding at the beginning of the reporting period + those are currently the same state
        if age_group == 'Pregnant'
          tmp_arr = []
          (tmp || []).each do |data|
            begin
              date_enrolled = data['date_enrolled'].to_date
            rescue StandardError
              raise data.inspect
            end
            earliest_start_date = begin
              data['earliest_start_date']
            rescue StandardError
              date_enrolled
            end

            imstaus = data['initial_maternal_status']
            mstatus = data['mstatus']

            if (date_enrolled >= start_date && date_enrolled <= end_date) && imstaus == 'FP' && (date_enrolled == earliest_start_date)
              tmp_arr << data
            elsif mstatus == 'FP'
              tmp_arr << data
            end
          end

          tmp = tmp_arr
        end

        if age_group == 'Breastfeeding'
          tmp_arr = []
          (tmp || []).each do |data|
            begin
              date_enrolled = data['date_enrolled'].to_date
            rescue StandardError
              raise data.inspect
            end
            earliest_start_date = begin
              data['earliest_start_date']
            rescue StandardError
              date_enrolled
            end

            imstaus = data['initial_maternal_status']
            mstatus = data['mstatus']

            if (date_enrolled >= start_date && date_enrolled <= end_date) && imstaus == 'FBf' && (date_enrolled == earliest_start_date)
              tmp_arr << data
            elsif mstatus == 'FBf'
              tmp_arr << data
            end
          end

          tmp = tmp_arr
        end
        # ........................... Hack ends .......... Will clean up later

        on_art = []
        all_clients = []
        all_clients_outcomes = {}

        (tmp || []).each do |pat|
          patient_id = pat['patient_id'].to_i
          outcome = pat['outcome']

          on_art << patient_id if outcome == 'On antiretrovirals'
          all_clients << patient_id
          all_clients_outcomes[patient_id] = outcome
        end

        list = {}

        if all_clients.blank? && %w[Breastfeeding Pregnant].include?(age_group)
          list[age_group] = {}
          list[age_group]['F'] = {
            tx_new: [], tx_curr: [],
            tx_screened_for_tb: [],
            tx_given_ipt: []
          }
          return list
        elsif all_clients.blank?
          return {}
        end

        big_insert tmp, age_group if age_group.match(/year|month/i)

        (tmp || []).each do |r|
          gender = r['gender']&.first || 'Unknown'
          patient_id = r['patient_id'].to_i
          tx_new, tx_curr, tx_given_ipt, tx_screened_for_tb = get_numbers(r, age_group, start_date, end_date,
                                                                          all_clients_outcomes)

          list[age_group] = {} if list[age_group].blank?

          if list[age_group][gender].blank?
            list[age_group][gender] = {
              tx_new: [], tx_curr: [],
              tx_screened_for_tb: [],
              tx_given_ipt: []
            }
          end

          list[age_group][gender][:tx_new] << r['patient_id'] if tx_new
          list[age_group][gender][:tx_curr] << r['patient_id'] if tx_curr
          list[age_group][gender][:tx_given_ipt] << r['patient_id'] if tx_given_ipt
          list[age_group][gender][:tx_screened_for_tb] << r['patient_id'] if tx_screened_for_tb

          date_enrolled = r['date_enrolled'].to_date

          if gender == 'F' && all_clients_outcomes[patient_id] == 'On antiretrovirals'
            insert_female_maternal_status(patient_id, age_group, end_date)
          elsif gender == 'F' && (date_enrolled >= start_date && date_enrolled <= end_date)
            insert_female_maternal_status(patient_id, age_group, end_date)
          end
        end

        list
      end

      def generate_start_date_and_end_date(quarter)
        return [@start_date, @end_date] if quarter == 'Custom'

        quarter, quarter_year = quarter.humanize.split(' ')

        quarter_start_dates = [
          "#{quarter_year}-01-01".to_date,
          "#{quarter_year}-04-01".to_date,
          "#{quarter_year}-07-01".to_date,
          "#{quarter_year}-10-01".to_date
        ]

        quarter_end_dates = [
          "#{quarter_year}-03-31".to_date,
          "#{quarter_year}-06-30".to_date,
          "#{quarter_year}-09-30".to_date,
          "#{quarter_year}-12-31".to_date
        ]

        current_quarter   = (quarter.match(/\d+/).to_s.to_i - 1)
        quarter_beginning = quarter_start_dates[current_quarter]
        quarter_ending    = quarter_end_dates[current_quarter]

        [quarter_beginning, quarter_ending]
      end

      def screened_for_tb(my_patient_id, age_group, start_date, end_date)
        data = ActiveRecord::Base.connection.select_one <<~SQL
          SELECT patient_screened_for_tb(#{my_patient_id},
            '#{start_date.to_date}', '#{end_date.to_date}') AS screened;
        SQL

        screened = data['screened'].to_i

        ActiveRecord::Base.connection.execute <<~SQL
          UPDATE temp_disaggregated SET screened_for_tb =  #{screened},
          age_group = '#{age_group}'
          WHERE patient_id = #{my_patient_id};
        SQL

        screened
      end

      def given_ipt(my_patient_id, age_group, start_date, end_date)
        data = ActiveRecord::Base.connection.select_one <<~SQL
          SELECT patient_given_ipt(#{my_patient_id},
            '#{start_date.to_date}', '#{end_date.to_date}') AS given;
        SQL

        given = data['given'].to_i

        ActiveRecord::Base.connection.execute <<~SQL
          UPDATE temp_disaggregated SET given_ipt =  #{given} ,
          age_group = '#{age_group}'
          WHERE patient_id = #{my_patient_id};
        SQL

        given
      end

      def get_numbers(data, age_group, start_date, end_date, outcomes)
        patient_id = data['patient_id'].to_i
        tx_new = false
        tx_curr = false
        tx_screened_for_tb = false
        tx_given_ipt = false
        outcome = outcomes[patient_id]

        begin
          date_enrolled = data['date_enrolled'].to_date
        rescue StandardError
          raise data.inspect
        end
        earliest_start_date = begin
          data['earliest_start_date'].to_date
        rescue StandardError
          nil
        end

        if date_enrolled >= start_date && date_enrolled <= end_date
          tx_new = true if !earliest_start_date.blank? && (date_enrolled == earliest_start_date)

          tx_curr = true if outcome == 'On antiretrovirals'
        elsif outcome == 'On antiretrovirals'
          tx_curr = true
        end

        if age_group == 'Pregnant'
          tx_new = false if data['initial_maternal_status'] != 'FP' && tx_new

          tx_curr = false if data['mstatus'] != 'FP'
        end

        if age_group == 'Breastfeeding'
          tx_new = false if data['initial_maternal_status'] != 'FBf' && tx_new

          tx_curr = false if data['mstatus'] != 'FBf'
        end

        [tx_new, tx_curr, tx_given_ipt, tx_screened_for_tb]
      end

      def get_age_groups(age_group, _start_date, _end_date)
        if age_group != 'Pregnant' && age_group != 'FNP' && age_group != 'Not pregnant' && age_group != 'Breastfeeding'

          # Handle 'All' age group separately - include all patients
          if age_group == 'All'
            age_group_patients = ActiveRecord::Base.connection.select_all <<~SQL
              SELECT
                patient_id, `disaggregated_age_group`(date(birthdate), date('#{@end_date}')) AS age_group
              FROM #{temp_earliest_start_date} e
              GROUP BY e.patient_id;
            SQL
          else
            age_group_patients = ActiveRecord::Base.connection.select_all <<~SQL
              SELECT
                patient_id, `disaggregated_age_group`(date(birthdate), date('#{@end_date}')) AS age_group
              FROM #{temp_earliest_start_date} e
              GROUP BY e.patient_id HAVING age_group COLLATE utf8mb3_unicode_ci = '#{age_group}' COLLATE utf8mb3_unicode_ci;
            SQL
          end

          age_group_patient_ids = [0]
          (age_group_patients || []).each do |patient|
            age_group_patient_ids << patient['patient_id'].to_i
          end

          results = ActiveRecord::Base.connection.select_all <<~SQL
            SELECT
              o.#{@type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}cum_outcome AS outcome, e.*
            FROM #{temp_earliest_start_date} e
            LEFT JOIN #{temp_patient_outcomes} o ON o.patient_id = e.patient_id
            WHERE date_enrolled <= '#{@end_date}'
            AND e.patient_id IN(#{age_group_patient_ids.join(',')})
            GROUP BY e.patient_id;
          SQL
        #           results = ActiveRecord::Base.connection.select_all <<~SQL
        #             SELECT
        #               `cohort_disaggregated_age_group`(date(birthdate), date('#{@end_date}')) AS age_group,
        #               o.cum_outcome AS outcome, e.*
        #             FROM earliest_start_date e
        #             LEFT JOIN temp_patient_outcomes o ON o.patient_id = e.patient_id
        #             WHERE  date_enrolled IS NOT NULL AND DATE(date_enrolled) <= DATE('#{@end_date}')
        #             AND e.patient_id NOT IN(#{visiting_clients.blank? ? 0 : visiting_clients.join(',')})
        #             GROUP BY e.patient_id HAVING age_group = '#{age_group}';
        #           SQL

        elsif age_group == 'Pregnant'
          create_mysql_female_maternal_status
          results = ActiveRecord::Base.connection.select_all <<~SQL
            SELECT
              e.*, maternal_status AS mstatus,
              t2.initial_maternal_status,
              t3.#{@type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}cum_outcome AS outcome
            FROM #{temp_earliest_start_date} e
            INNER JOIN temp_disaggregated t2 ON t2.patient_id = e.patient_id
            INNER JOIN #{temp_patient_outcomes} t3 ON t3.patient_id = e.patient_id
            WHERE maternal_status COLLATE utf8mb3_unicode_ci = 'FP' COLLATE utf8mb3_unicode_ci 
              OR initial_maternal_status COLLATE utf8mb3_unicode_ci = 'FP' COLLATE utf8mb3_unicode_ci
            GROUP BY e.patient_id;
          SQL

        elsif age_group == 'Breastfeeding'
          create_mysql_female_maternal_status
          results = ActiveRecord::Base.connection.select_all <<~SQL
            SELECT
              e.*, maternal_status AS mstatus,
              initial_maternal_status,
              t3.#{@type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}cum_outcome AS outcome
            FROM #{temp_earliest_start_date} e
            INNER JOIN temp_disaggregated t2 ON t2.patient_id = e.patient_id
            INNER JOIN #{temp_patient_outcomes} t3 ON t3.patient_id = e.patient_id
            WHERE maternal_status COLLATE utf8mb3_unicode_ci = 'FBf' COLLATE utf8mb3_unicode_ci 
              OR initial_maternal_status COLLATE utf8mb3_unicode_ci = 'FBf' COLLATE utf8mb3_unicode_ci
            GROUP BY e.patient_id;
          SQL

        elsif age_group == 'FNP'
          create_mysql_female_maternal_status
          results = ActiveRecord::Base.connection.select_all <<~SQL
            SELECT
              e.*, maternal_status AS mstatus,
              initial_maternal_status,
              t3.#{@type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}cum_outcome AS outcome
            FROM #{temp_earliest_start_date} e
            INNER JOIN temp_disaggregated t2 ON t2.patient_id = e.patient_id
            INNER JOIN #{temp_patient_outcomes} t3 ON t3.patient_id = e.patient_id
            WHERE maternal_status COLLATE utf8mb3_unicode_ci = 'FNP' COLLATE utf8mb3_unicode_ci
            GROUP BY e.patient_id;
          SQL

        end

        results
      end

      def create_mysql_female_maternal_status
        ActiveRecord::Base.connection.execute <<~SQL
          DROP FUNCTION IF EXISTS female_maternal_status;
        SQL

        ActiveRecord::Base.connection.execute <<~SQL
          CREATE FUNCTION female_maternal_status(my_patient_id int, end_datetime datetime) RETURNS VARCHAR(20)
          DETERMINISTIC
          BEGIN

          DECLARE breastfeeding_date DATETIME;
          DECLARE pregnant_date DATETIME;
          DECLARE maternal_status VARCHAR(20);
          DECLARE obs_value_coded INT(11);


          SET @reason_for_starting = (SELECT concept_id FROM concept_name WHERE name = 'Reason for ART eligibility' LIMIT 1);
          SET @yes_concept := (SELECT concept_id FROM concept_name WHERE name = 'Yes' AND locale_preferred = 1 AND voided = 0 LIMIT 1);
          SET @no_concept := (SELECT concept_id FROM concept_name WHERE name = 'No' AND locale_preferred = 1 AND voided = 0 LIMIT 1);

          SET @pregnant_concepts := (SELECT GROUP_CONCAT(concept_id) FROM concept_name WHERE name IN('Is patient pregnant?','Patient pregnant'));
          SET @breastfeeding_concept := (SELECT GROUP_CONCAT(concept_id) FROM concept_name WHERE name = 'Breastfeeding');

          SET pregnant_date = (SELECT MAX(obs_datetime) FROM obs WHERE concept_id IN(@pregnant_concepts) AND voided = 0 AND person_id = my_patient_id AND obs_datetime <= end_datetime);
          SET breastfeeding_date = (SELECT MAX(obs_datetime) FROM obs WHERE concept_id IN(@breastfeeding_concept) AND voided = 0 AND person_id = my_patient_id AND obs_datetime <= end_datetime);

          IF pregnant_date IS NULL THEN
            SET pregnant_date = (SELECT MAX(obs_datetime) FROM obs WHERE concept_id = @reason_for_starting AND voided = 0 AND person_id = my_patient_id AND obs_datetime <= end_datetime AND value_coded IN(1755));
          END IF;

          IF breastfeeding_date IS NULL THEN
            SET breastfeeding_date = (SELECT MAX(obs_datetime) FROM obs WHERE concept_id = @reason_for_starting AND voided = 0 AND person_id = my_patient_id AND obs_datetime <= end_datetime AND value_coded IN(834,5632));
          END IF;

          IF pregnant_date IS NULL AND breastfeeding_date IS NULL THEN SET maternal_status = "FNP";
          ELSEIF pregnant_date IS NOT NULL AND breastfeeding_date IS NOT NULL THEN SET maternal_status = "Unknown";
          ELSEIF pregnant_date IS NULL AND breastfeeding_date IS NOT NULL THEN SET maternal_status = "Check BF";
          ELSEIF pregnant_date IS NOT NULL AND breastfeeding_date IS NULL THEN SET maternal_status = "Check FP";
          END IF;

          IF maternal_status = 'Unknown' THEN

            IF breastfeeding_date <= pregnant_date THEN
              SET obs_value_coded = (SELECT value_coded FROM obs WHERE concept_id IN(@pregnant_concepts) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = pregnant_date LIMIT 1);
              IF obs_value_coded = @yes_concept THEN SET maternal_status = 'FP';
              ELSEIF obs_value_coded = @no_concept THEN SET maternal_status = 'FNP';
              END IF;
            END IF;

            IF breastfeeding_date > pregnant_date THEN
              SET obs_value_coded = (SELECT value_coded FROM obs WHERE concept_id IN(@breastfeeding_concept) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = breastfeeding_date LIMIT 1);
              IF obs_value_coded = @yes_concept THEN SET maternal_status = 'FBf';
              ELSEIF obs_value_coded = @no_concept THEN SET maternal_status = 'FNP';
              END IF;
            END IF;

            IF DATE(breastfeeding_date) = DATE(pregnant_date) AND maternal_status = 'FNP' THEN
              SET obs_value_coded = (SELECT value_coded FROM obs WHERE concept_id IN(@breastfeeding_concept) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = breastfeeding_date LIMIT 1);
              IF obs_value_coded = @yes_concept THEN SET maternal_status = 'FBf';
              ELSEIF obs_value_coded = @no_concept THEN SET maternal_status = 'FNP';
              END IF;
            END IF;
          END IF;

          IF maternal_status = 'Check FP' THEN

            SET obs_value_coded = (SELECT value_coded FROM obs WHERE concept_id IN(@pregnant_concepts) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = pregnant_date LIMIT 1);
            IF obs_value_coded = @yes_concept THEN SET maternal_status = 'FP';
            ELSEIF obs_value_coded = @no_concept THEN SET maternal_status = 'FNP';
            END IF;

            IF obs_value_coded IS NULL THEN
              SET obs_value_coded = (SELECT GROUP_CONCAT(value_coded) FROM obs WHERE concept_id IN(7563) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = pregnant_date);
              IF obs_value_coded IN(1755) THEN SET maternal_status = 'FP';
              END IF;
            END IF;

            IF maternal_status = 'Check FP' THEN SET maternal_status = 'FNP';
            END IF;
          END IF;

          IF maternal_status = 'Check BF' THEN

            SET obs_value_coded = (SELECT value_coded FROM obs WHERE concept_id IN(@breastfeeding_concept) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = breastfeeding_date LIMIT 1);
            IF obs_value_coded = @yes_concept THEN SET maternal_status = 'FBf';
            ELSEIF obs_value_coded = @no_concept THEN SET maternal_status = 'FNP';
            END IF;

            IF obs_value_coded IS NULL THEN
              SET obs_value_coded = (SELECT GROUP_CONCAT(value_coded) FROM obs WHERE concept_id IN(7563) AND voided = 0 AND person_id = my_patient_id AND obs_datetime = breastfeeding_date);
              IF obs_value_coded IN(834,5632) THEN SET maternal_status = 'FBf';
              END IF;
            END IF;

            IF maternal_status = 'Check BF' THEN SET maternal_status = 'FNP';
            END IF;
          END IF;



          RETURN maternal_status;
          END;
        SQL
      end

      def rebuild_outcomes(report_type)
        ArtService::Reports::CohortBuilder.new(outcomes_definition: report_type).init_temporary_tables(@start_date,
                                                                                                       @end_date, @occupation)
      end

      def insert_female_maternal_status(patient_id, age_group, end_date)
        encounter_types = []
        encounter_types << EncounterType.find_by_name('HIV CLINIC CONSULTATION').encounter_type_id
        encounter_types << EncounterType.find_by_name('HIV STAGING').encounter_type_id

        pregnant_concepts = []
        pregnant_concepts << ConceptName.find_by_name('Is patient pregnant?').concept_id
        pregnant_concepts << ConceptName.find_by_name('patient pregnant').concept_id

        yes_concept_id = ConceptName.find_by(name: 'Yes')&.concept_id

        results = ActiveRecord::Base.connection.select_all(
          "SELECT person_id, obs.value_coded value_coded FROM obs obs
            INNER JOIN encounter enc ON enc.encounter_id = obs.encounter_id
            AND enc.voided = 0 AND enc.program_id = 1
          WHERE obs.person_id = #{patient_id}
          AND obs.obs_datetime <= '#{end_date.to_date.strftime('%Y-%m-%d 23:59:59')}'
          AND obs.concept_id IN(#{pregnant_concepts.join(',')})
          AND obs.voided = 0 AND enc.encounter_type IN(#{encounter_types.join(',')})
          AND DATE(obs.obs_datetime) = (SELECT MAX(DATE(o.obs_datetime)) FROM obs o
                        INNER JOIN encounter e ON e.encounter_id = o.encounter_id
                        AND e.program_id = 1 AND e.voided = 0
                        WHERE o.concept_id IN(#{pregnant_concepts.join(',')})
                        AND o.voided = 0 AND o.person_id = obs.person_id
                        AND o.obs_datetime <= '#{end_date.to_date.strftime('%Y-%m-%d 23:59:59')}')
          GROUP BY obs.person_id HAVING value_coded = #{yes_concept_id}
          ORDER BY obs.obs_datetime DESC;"
        )

        female_maternal_status = results.blank? ? 'FNP' : 'FP'

        if female_maternal_status == 'FNP'

          breastfeeding_concepts = []
          breastfeeding_concepts <<  ConceptName.find_by_name('Breast feeding?').concept_id
          breastfeeding_concepts <<  ConceptName.find_by_name('Breast feeding').concept_id
          breastfeeding_concepts <<  ConceptName.find_by_name('Breastfeeding').concept_id

          results2 = ActiveRecord::Base.connection.select_all(
            "SELECT person_id, obs.value_coded value_coded  FROM obs obs
            INNER JOIN encounter enc ON enc.encounter_id = obs.encounter_id
            AND enc.voided = 0 AND enc.program_id = 1
          WHERE obs.person_id =#{patient_id}
          AND obs.obs_datetime <= '#{end_date.to_date.strftime('%Y-%m-%d 23:59:59')}'
          AND obs.concept_id IN(#{breastfeeding_concepts.join(',')})
          AND obs.voided = 0 AND enc.encounter_type IN(#{encounter_types.join(',')})
          AND DATE(obs.obs_datetime) = (SELECT MAX(DATE(o.obs_datetime)) FROM obs o
                        INNER JOIN encounter e ON e.encounter_id = o.encounter_id
                        AND e.program_id = 1 AND e.voided = 0
                        WHERE o.concept_id IN(#{breastfeeding_concepts.join(',')}) AND o.voided = 0
                        AND o.person_id = obs.person_id
                        AND o.obs_datetime <='#{end_date.to_date.strftime('%Y-%m-%d 23:59:59')}')
          GROUP BY obs.person_id HAVING value_coded = #{yes_concept_id}
          ORDER BY obs.obs_datetime DESC;"
          )

          female_maternal_status = results2.blank? ? 'FNP' : 'FBf'
        end

        results = ActiveRecord::Base.connection.select_all(
          "SELECT person_id, obs.value_coded value_coded FROM obs obs
            INNER JOIN encounter enc ON enc.encounter_id = obs.encounter_id
            AND enc.voided = 0 AND enc.program_id = 1
          WHERE obs.person_id = #{patient_id}
          AND obs.obs_datetime <= '#{end_date.to_date.strftime('%Y-%m-%d 23:59:59')}'
          AND obs.concept_id IN(#{pregnant_concepts.join(',')})
          AND obs.voided = 0 AND enc.encounter_type IN(#{encounter_types.join(',')})
          AND DATE(obs.obs_datetime) = (SELECT DATE(es.earliest_start_date) FROM #{temp_earliest_start_date} es
                                        WHERE es.patient_id = obs.person_id)
          GROUP BY obs.person_id HAVING value_coded = #{yes_concept_id}
          ORDER BY obs.obs_datetime DESC;"
        )

        initial_female_maternal_status = results.blank? ? 'FNP' : 'FP'

        if initial_female_maternal_status == 'FNP'

          breastfeeding_concepts = []
          breastfeeding_concepts <<  ConceptName.find_by_name('Breast feeding?').concept_id
          breastfeeding_concepts <<  ConceptName.find_by_name('Breast feeding').concept_id
          breastfeeding_concepts <<  ConceptName.find_by_name('Breastfeeding').concept_id

          results2 = ActiveRecord::Base.connection.select_all(
            "SELECT person_id, obs.value_coded value_coded  FROM obs obs
            INNER JOIN encounter enc ON enc.encounter_id = obs.encounter_id
            AND enc.voided = 0 AND enc.program_id = 1
          WHERE obs.person_id =#{patient_id}
          AND obs.obs_datetime <= '#{end_date.to_date.strftime('%Y-%m-%d 23:59:59')}'
          AND obs.concept_id IN(#{breastfeeding_concepts.join(',')})
          AND obs.voided = 0 AND enc.encounter_type IN(#{encounter_types.join(',')})
          AND DATE(obs.obs_datetime) = (SELECT DATE(es.earliest_start_date) FROM #{temp_earliest_start_date} es
                                        WHERE es.patient_id = obs.person_id)
          GROUP BY obs.person_id HAVING value_coded = #{yes_concept_id}
          ORDER BY obs.obs_datetime DESC;"
          )

          initial_female_maternal_status = results2.blank? ? 'FNP' : 'FBf'
        end

        ActiveRecord::Base.connection.execute <<~SQL
          UPDATE temp_disaggregated SET maternal_status =  '#{female_maternal_status}',
            initial_maternal_status = '#{initial_female_maternal_status}',
             age_group = '#{age_group}' WHERE patient_id = #{patient_id};
        SQL
      end

      def big_insert(data, age_group)
        insert_array = []
        (data || []).each do |r|
          insert_array << "(#{r['patient_id']}, '#{age_group}')"
        end

        return if insert_array.blank?

        ActiveRecord::Base.connection.execute <<~SQL
          INSERT INTO temp_disaggregated (patient_id, age_group)
          VALUES #{insert_array.join(',')};
        SQL
        #         (data || []).each do |r|
        #           ActiveRecord::Base.connection.execute <<~SQL
        #             INSERT INTO temp_disaggregated (patient_id, age_group)
        #             VALUES(#{r['patient_id']}, '#{age_group}');
        # SQL
        #         end
      end
    end
  end
end
