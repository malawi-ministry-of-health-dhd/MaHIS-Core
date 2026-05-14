module NcdService
  module Reports
    class NcdDashboard
      def find_report(start_date:, end_date:, **extra_kwargs)
        @sections = extra_kwargs[:sections] || []
        @sections = [@sections] if @sections.is_a?(String)
        dashboard
      end

      def dashboard
        @current_date = Date.current
        @location_id = User.current.location_id
        create_cohort_table
        result = data(sections: @sections)
        drop_cohort_table
        result
      end

      def data(sections: [])
        res = {}
        all_sections = sections.blank? || sections.include?('all')

        if all_sections || sections.include?('stats')
          res.merge!({
            total_client_registered: total_cohort_count,
            total_male_registered: total_male_registered,
            total_female_registered: total_female_registered,
            total_complications: total_complications,
            total_defaulters: count_defaulters,
            total_pending_dispensations: count_pending_dispensations
          })
        end

        if all_sections || sections.include?('pending_ncd')
          pending_data = pending_ncd_data
          res.merge!({
            total_pending_ncd_numbers: pending_data[:count],
            pending_ncd_patients: pending_data[:patients]
          })
        end

        if all_sections || sections.include?('defaulters')
          res[:defaulter_alerts] = get_defaulter_alerts
        end

        if all_sections || sections.include?('top_conditions')
          res[:top_conditions] = get_top_conditions
        end

        if all_sections || sections.include?('gender_chart')
          gender_quarterly_data = gender_quarterly_breakdown
          res[:gender_data] = {
            categories: gender_quarterly_data[:categories],
            series: [
              { name: 'Male', data: gender_quarterly_data[:male], group: 'apexcharts-axis-0' },
              { name: 'Female', data: gender_quarterly_data[:female], group: 'apexcharts-axis-0' }
            ]
          }
        end

        if all_sections || sections.include?('diagnosis_chart')
          diagnosis_quarterly_data = diagnosis_quarterly_breakdown
          res[:diagnosis_data] = {
            categories: diagnosis_quarterly_data[:categories],
            series: [
              { name: 'Type 1 Diabetes', data: diagnosis_quarterly_data[:type_one], group: 'apexcharts-axis-0' },
              { name: 'Type 2 Diabetes', data: diagnosis_quarterly_data[:type_two], group: 'apexcharts-axis-0' },
              { name: 'Hypertension', data: diagnosis_quarterly_data[:hypertension], group: 'apexcharts-axis-0' }
            ]
          }
        end
        res
      end

      private

      def create_cohort_table
        program = Program.find_by_name('NCD PROGRAM')
        program_id = program&.id || 32
        ncd_type_id = PatientIdentifierType.find_by_name('NCD Number')&.id || 31
        
        Rails.logger.debug "NCD Dashboard: Generating for Program ID #{program_id} and Identifier ID #{ncd_type_id}"
        
        ActiveRecord::Base.connection.execute("DROP TEMPORARY TABLE IF EXISTS temp_ncd_cohort")
        
        sql = <<-SQL
          CREATE TEMPORARY TABLE temp_ncd_cohort (
            patient_id INT PRIMARY KEY
          ) AS
          SELECT DISTINCT patient_id
          FROM (
            SELECT patient_id FROM patient_program WHERE program_id = #{program_id} AND voided = 0
            UNION
            SELECT patient_id FROM patient_identifier WHERE identifier_type = #{ncd_type_id} AND voided = 0
            UNION
            SELECT patient_id FROM encounter WHERE program_id = #{program_id} AND voided = 0
          ) AS all_ncd_patients
        SQL
        
        ActiveRecord::Base.connection.execute(sql)
        count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM temp_ncd_cohort").to_i
        Rails.logger.debug "NCD Dashboard: Found #{count} patients in cohort"
      end

      def drop_cohort_table
        ActiveRecord::Base.connection.execute("DROP TEMPORARY TABLE IF EXISTS temp_ncd_cohort")
      end

      def total_cohort_count
        ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM temp_ncd_cohort").to_i
      end

      def total_male_registered
        ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM person p INNER JOIN temp_ncd_cohort c ON c.patient_id = p.person_id WHERE p.gender = 'M' AND p.voided = 0"
        ).to_i
      end

      def total_female_registered
        ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM person p INNER JOIN temp_ncd_cohort c ON c.patient_id = p.person_id WHERE p.gender = 'F' AND p.voided = 0"
        ).to_i
      end

      def total_complications
        sql = <<-SQL
          SELECT COUNT(DISTINCT o.person_id) 
          FROM obs o
          INNER JOIN temp_ncd_cohort c ON c.patient_id = o.person_id
          INNER JOIN encounter e ON e.encounter_id = o.encounter_id AND e.voided = 0
          INNER JOIN encounter_type et ON et.encounter_type_id = e.encounter_type AND et.name = 'COMPLICATIONS'
          WHERE o.voided = 0
        SQL
        ActiveRecord::Base.connection.select_value(sql).to_i
      end

      def count_defaulters
        cutoff_date = Date.current - 60.days
        
        sql = <<-SQL
          SELECT COUNT(DISTINCT o.patient_id)
          FROM orders o
          INNER JOIN temp_ncd_cohort c ON c.patient_id = o.patient_id
          INNER JOIN drug_order do ON do.order_id = o.order_id
          INNER JOIN obs ON obs.order_id = o.order_id
          INNER JOIN concept_name cn ON cn.concept_id = obs.concept_id AND cn.name = 'AMOUNT DISPENSED'
          WHERE o.voided = 0 AND obs.voided = 0
          AND do.quantity IS NOT NULL
          AND obs.value_numeric IS NOT NULL
          AND o.start_date BETWEEN '#{cutoff_date - 60.days}' AND '#{cutoff_date}'
          AND NOT EXISTS (
            SELECT 1 FROM orders o2 
            INNER JOIN drug_order do2 ON do2.order_id = o2.order_id
            WHERE o2.patient_id = o.patient_id 
            AND o2.start_date > '#{cutoff_date}'
            AND o2.voided = 0
          )
        SQL
        ActiveRecord::Base.connection.select_value(sql).to_i
      end

      def get_defaulter_alerts
        cutoff_date = Date.current - 60.days
        cutoff_120 = Date.current - 120.days
        
        sql = <<-SQL
          SELECT o.patient_id, n.given_name, n.family_name, MAX(o.start_date) as last_dispensation
          FROM orders o
          INNER JOIN temp_ncd_cohort c ON c.patient_id = o.patient_id
          INNER JOIN drug_order do ON do.order_id = o.order_id
          INNER JOIN obs ON obs.order_id = o.order_id
          INNER JOIN concept_name cn ON cn.concept_id = obs.concept_id AND cn.name = 'AMOUNT DISPENSED'
          INNER JOIN person_name n ON n.person_id = o.patient_id AND n.voided = 0
          WHERE o.voided = 0 AND obs.voided = 0
          AND do.quantity > 0
          AND obs.value_numeric IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM orders o2 
            INNER JOIN drug_order do2 ON do2.order_id = o2.order_id
            WHERE o2.patient_id = o.patient_id 
            AND o2.start_date > '#{cutoff_date}'
            AND o2.voided = 0
          )
          GROUP BY o.patient_id, n.given_name, n.family_name
          HAVING MAX(o.start_date) BETWEEN '#{cutoff_120}' AND '#{cutoff_date}'
          ORDER BY last_dispensation ASC
          LIMIT 5
        SQL
        
        results = ActiveRecord::Base.connection.select_all(sql)
        
        alerts = []
        results.each do |row|
          last_disp = row['last_dispensation'].to_date
          diff_days = (Date.current - last_disp).to_i
          
          alerts << {
            id: row['patient_id'],
            name: "#{row['given_name']} #{row['family_name']}".strip,
            missedCount: 1,
            timeAgo: "#{diff_days} days ago"
          }
        end
        
        alerts
      end

      def count_pending_dispensations
        sql = <<-SQL
          SELECT COUNT(DISTINCT o.patient_id)
          FROM orders o
          INNER JOIN temp_ncd_cohort c ON c.patient_id = o.patient_id
          INNER JOIN drug_order do ON do.order_id = o.order_id
          WHERE o.voided = 0
          AND do.quantity <= 0
        SQL
        ActiveRecord::Base.connection.select_value(sql).to_i
      end

      def pending_ncd_data
        ncd_type_id = PatientIdentifierType.find_by_name('NCD Number')&.id
        return { count: 0, patients: [] } unless ncd_type_id
        
        sql = <<-SQL
          SELECT p.person_id, n.given_name, n.family_name, p.date_created
          FROM person p
          INNER JOIN temp_ncd_cohort c ON c.patient_id = p.person_id
          INNER JOIN person_name n ON n.person_id = p.person_id AND n.voided = 0
          WHERE p.voided = 0
          AND NOT EXISTS (
            SELECT 1 FROM patient_identifier pi 
            WHERE pi.patient_id = p.person_id 
            AND pi.identifier_type = #{ncd_type_id} 
            AND pi.voided = 0
          )
          ORDER BY p.date_created DESC
        SQL
        
        results = ActiveRecord::Base.connection.select_all(sql)
        
        patients = results.first(5).map do |row|
          {
            id: row['person_id'],
            name: "#{row['given_name']} #{row['family_name']}".strip.presence || "Unknown Patient",
            date: row['date_created']
          }
        end
        
        {
          count: results.length,
          patients: patients
        }
      end

      def get_top_conditions
        sql = <<-SQL
          SELECT o.value_coded, COUNT(*) as cnt
          FROM (
            SELECT obs.person_id, obs.value_coded,
                   ROW_NUMBER() OVER (PARTITION BY obs.person_id ORDER BY obs.obs_datetime DESC) as rn
            FROM obs
            INNER JOIN temp_ncd_cohort c ON c.patient_id = obs.person_id
            INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.voided = 0
            INNER JOIN encounter_type et ON et.encounter_type_id = e.encounter_type AND et.name = 'DIAGNOSIS'
            WHERE obs.voided = 0 AND obs.concept_id = #{concept_id('Primary diagnosis')}
          ) o
          WHERE o.rn = 1
          GROUP BY o.value_coded
        SQL
        
        results = ActiveRecord::Base.connection.select_all(sql)
        
        type1 = 0
        type2 = 0
        hyper = 0
        other = 0
        
        results.each do |row|
          val = row['value_coded'].to_i
          cnt = row['cnt'].to_i
          if val == concept_id('Type 1 diabetes mellitus')
            type1 += cnt
          elsif val == concept_id('Type 2 diabetes mellitus')
            type2 += cnt
          elsif val == concept_id('Hypertension')
            hyper += cnt
          else
            other += cnt
          end
        end
        
        total = type1 + type2 + hyper + other
        return [] if total == 0
        
        conditions = [
          { name: 'Type 2 Diabetes', count: type2, percent: ((type2.to_f / total) * 100).round },
          { name: 'Hypertension', count: hyper, percent: ((hyper.to_f / total) * 100).round },
          { name: 'Type 1 Diabetes', count: type1, percent: ((type1.to_f / total) * 100).round },
          { name: 'Other NCDs', count: other, percent: ((other.to_f / total) * 100).round }
        ]
        
        conditions.sort_by { |c| -c[:count] }
      end

      def diagnosis_quarterly_breakdown
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          sql = <<-SQL
            SELECT o.value_coded, COUNT(*) as cnt
            FROM (
              SELECT obs.person_id, obs.value_coded,
                     ROW_NUMBER() OVER (PARTITION BY obs.person_id ORDER BY obs.obs_datetime DESC) as rn
              FROM obs
              INNER JOIN temp_ncd_cohort c ON c.patient_id = obs.person_id
              INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.voided = 0
              INNER JOIN encounter_type et ON et.encounter_type_id = e.encounter_type AND et.name = 'DIAGNOSIS'
              WHERE obs.voided = 0 
              AND obs.concept_id = #{concept_id('Primary diagnosis')}
              AND obs.obs_datetime BETWEEN '#{start_date.beginning_of_day.strftime('%Y-%m-%d %H:%M:%S')}' AND '#{end_date.end_of_day.strftime('%Y-%m-%d %H:%M:%S')}'
            ) o
            WHERE o.rn = 1
            GROUP BY o.value_coded
          SQL
          
          results = ActiveRecord::Base.connection.select_all(sql)
          
          type1 = 0
          type2 = 0
          hyper = 0
          
          results.each do |row|
            val = row['value_coded'].to_i
            cnt = row['cnt'].to_i
            if val == concept_id('Type 1 diabetes mellitus')
              type1 += cnt
            elsif val == concept_id('Type 2 diabetes mellitus')
              type2 += cnt
            elsif val == concept_id('Hypertension')
              hyper += cnt
            end
          end
          
          quarters[quarter_label] = {
            type_one: type1,
            type_two: type2,
            hypertension: hyper
          }
          
          end_date = start_date - 1.day
        end
        
        reversed_quarters = quarters.to_a.reverse.to_h
        
        {
          categories: reversed_quarters.keys,
          type_one: reversed_quarters.values.map { |q| q[:type_one] },
          type_two: reversed_quarters.values.map { |q| q[:type_two] },
          hypertension: reversed_quarters.values.map { |q| q[:hypertension] }
        }
      end

      def gender_quarterly_breakdown
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          sql = <<-SQL
            SELECT p.gender, COUNT(DISTINCT p.person_id) as cnt
            FROM person p
            INNER JOIN temp_ncd_cohort c ON c.patient_id = p.person_id
            INNER JOIN obs ON obs.person_id = p.person_id
            WHERE p.voided = 0 AND obs.voided = 0
            AND obs.obs_datetime BETWEEN '#{start_date.beginning_of_day.strftime('%Y-%m-%d %H:%M:%S')}' AND '#{end_date.end_of_day.strftime('%Y-%m-%d %H:%M:%S')}'
            GROUP BY p.gender
          SQL
          
          results = ActiveRecord::Base.connection.select_all(sql)
          
          male = 0
          female = 0
          results.each do |row|
            if row['gender'] == 'M'
              male = row['cnt'].to_i
            elsif row['gender'] == 'F'
              female = row['cnt'].to_i
            end
          end
          
          quarters[quarter_label] = {
            male: male,
            female: female
          }
          
          end_date = start_date - 1.day
        end
        
        reversed_quarters = quarters.to_a.reverse.to_h
        
        {
          categories: reversed_quarters.keys,
          male: reversed_quarters.values.map { |q| q[:male] },
          female: reversed_quarters.values.map { |q| q[:female] }
        }
      end

      def format_quarter_label(date)
        quarter_number = ((date.month - 1) / 3) + 1
        "Q#{quarter_number} #{date.year}"
      end

      def concept_id(name)
        ConceptName.find_by_name(name)&.concept_id
      end
    end
  end
end