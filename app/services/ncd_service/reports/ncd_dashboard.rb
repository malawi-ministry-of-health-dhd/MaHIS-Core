module NcdService
  module Reports
    class NcdDashboard
      def find_report(start_date:, end_date:, **_extra_kwargs)
        dashboard
      end

      def dashboard
        @current_date = Date.current
        @location_id = User.current.location_id
        @patient_ids = get_patients
        data
      end

      def data
        gender_quarterly_data = gender_quarterly_breakdown
        diagnosis_quarterly_data = diagnosis_quarterly_breakdown
        pending_data = pending_ncd_data
        
        {
          total_client_registered: @patient_ids.count,
          total_male_registered: total_male_registered,
          total_female_registered: total_female_registered,
          total_complications: total_complications,
          total_defaulters: count_defaulters,
          total_pending_dispensations: count_pending_dispensations,
          total_pending_ncd_numbers: pending_data[:count],
          pending_ncd_patients: pending_data[:patients],
          defaulter_alerts: get_defaulter_alerts,
          top_conditions: get_top_conditions,
          gender_data: {
            categories: gender_quarterly_data[:categories],
            series: [
              {
                name: 'Male',
                data: gender_quarterly_data[:male],
                group: 'apexcharts-axis-0'
              },
              {
                name: 'Female',
                data: gender_quarterly_data[:female],
                group: 'apexcharts-axis-0'
              }
            ]
          },
          diagnosis_data: {
            categories: diagnosis_quarterly_data[:categories],
            series: [
              {
                name: 'Type 1 Diabetes',
                data: diagnosis_quarterly_data[:type_one],
                group: 'apexcharts-axis-0'
              },
              {
                name: 'Type 2 Diabetes',
                data: diagnosis_quarterly_data[:type_two],
                group: 'apexcharts-axis-0'
              },
              {
                name: 'Hypertension',
                data: diagnosis_quarterly_data[:hypertension],
                group: 'apexcharts-axis-0'
              }
            ]
          }
        }
      end

      private

      # Base query: Get all NCD patients
      def get_patients
        sql = <<-SQL
          SELECT DISTINCT pp.patient_id 
          FROM patient_program pp 
          WHERE pp.program_id = 32 
          AND pp.voided = 0
        SQL
        
        ActiveRecord::Base.connection.select_values(sql)
      end

      # Gender counts based on base patient cohort
      def total_male_registered
        return 0 if @patient_ids.empty?
        
        Person.where(person_id: @patient_ids, gender: 'M').count
      end

      def total_female_registered
        return 0 if @patient_ids.empty?
        
        Person.where(person_id: @patient_ids, gender: 'F').count
      end

      # Complications count for base patient cohort
      def total_complications
        return 0 if @patient_ids.empty?
        
        Observation.joins(encounter: :type)
                   .where(person_id: @patient_ids)
                   .where(encounter_type: { name: 'COMPLICATIONS' })
                   .distinct
                   .count(:person_id)
      end

      # Defaulters: patients from base cohort with last dispensation 60-120 days ago
      def count_defaulters
        return 0 if @patient_ids.empty?
        
        cutoff_date = Date.current - 60.days
        
        # Find patients whose last dispensation was between 60-120 days ago
        defaulting_patients = Patient.joins(orders: :drug_order)
                           .joins('INNER JOIN obs ON obs.order_id = orders.order_id')
                           .joins('INNER JOIN concept_name ON concept_name.concept_id = obs.concept_id')
                           .where(patient_id: @patient_ids)
                           .where('drug_order.quantity IS NOT NULL')
                           .where('orders.start_date BETWEEN ? AND ?', cutoff_date - 60.days, cutoff_date)
                           .where(
                             'concept_name.name = ? AND obs.value_numeric IS NOT NULL',
                             'AMOUNT DISPENSED'
                           )
                           .where('NOT EXISTS (
                             SELECT 1 FROM orders o 
                             INNER JOIN drug_order do ON do.order_id = o.order_id
                             WHERE o.patient_id = patient.patient_id 
                             AND o.start_date > ?
                           )', cutoff_date)
                           .distinct
                           .count(:patient_id)
        
        defaulting_patients
      end

      def get_defaulter_alerts
        return [] if @patient_ids.empty?
        
        cutoff_date = Date.current - 60.days
        cutoff_120 = Date.current - 120.days
        
        sql = <<-SQL
          SELECT o.patient_id, n.given_name, n.family_name, MAX(o.start_date) as last_dispensation
          FROM orders o
          INNER JOIN drug_order do ON do.order_id = o.order_id
          INNER JOIN obs ON obs.order_id = o.order_id
          INNER JOIN concept_name cn ON cn.concept_id = obs.concept_id AND cn.name = 'AMOUNT DISPENSED'
          INNER JOIN person_name n ON n.person_id = o.patient_id AND n.voided = 0
          WHERE o.patient_id IN (?)
          AND o.voided = 0
          AND do.quantity > 0
          AND obs.value_numeric IS NOT NULL
          GROUP BY o.patient_id
          HAVING MAX(o.start_date) BETWEEN ? AND ?
        SQL
        
        results = ActiveRecord::Base.connection.select_all(
          ActiveRecord::Base.sanitize_sql([sql, @patient_ids, cutoff_120, cutoff_date])
        )
        
        alerts = []
        results.each do |row|
          # double check no recent dispensation
          recent = Order.joins(:drug_order).where(patient_id: row['patient_id']).where('start_date > ?', cutoff_date).exists?
          next if recent
          
          last_disp = row['last_dispensation'].to_date
          diff_days = (Date.current - last_disp).to_i
          
          alerts << {
            id: row['patient_id'],
            name: "\#{row['given_name']} \#{row['family_name']}".strip.presence || "Unknown Patient",
            missedCount: 1,
            timeAgo: "\#{diff_days} days ago"
          }
        end
        
        alerts.sort_by { |a| -a[:timeAgo].to_i }.first(5)
      end

      # Pending dispensations for base patient cohort
      def count_pending_dispensations
        return 0 if @patient_ids.empty?
                
        DrugOrder.joins(order: :encounter)
                 .where('orders.patient_id IN (?)', @patient_ids)
                 .where('drug_order.quantity <= 0')
                 .distinct
                 .count('orders.patient_id')
      end

      def pending_ncd_data
        return { count: 0, patients: [] } if @patient_ids.empty?
        
        ncd_type_id = PatientIdentifierType.find_by_name('NCD Number')&.id
        return { count: 0, patients: [] } unless ncd_type_id
        
        sql = <<-SQL
          SELECT p.person_id, n.given_name, n.family_name, p.date_created
          FROM person p
          INNER JOIN person_name n ON n.person_id = p.person_id AND n.voided = 0
          WHERE p.person_id IN (?)
          AND p.voided = 0
          AND NOT EXISTS (
            SELECT 1 FROM patient_identifier pi 
            WHERE pi.patient_id = p.person_id 
            AND pi.identifier_type = ? 
            AND pi.voided = 0
          )
          ORDER BY p.date_created DESC
        SQL
        
        results = ActiveRecord::Base.connection.select_all(
          ActiveRecord::Base.sanitize_sql([sql, @patient_ids, ncd_type_id])
        )
        
        patients = results.map do |row|
          {
            id: row['person_id'],
            name: "\#{row['given_name']} \#{row['family_name']}".strip.presence || "Unknown Patient",
            date: row['date_created']
          }
        end
        
        {
          count: patients.length,
          patients: patients.first(5)
        }
      end

      def get_top_conditions
        return [] if @patient_ids.empty?
        
        sql = <<-SQL
          SELECT o.value_coded, COUNT(*) as cnt
          FROM (
            SELECT obs.person_id, obs.value_coded,
                   ROW_NUMBER() OVER (PARTITION BY obs.person_id ORDER BY obs.obs_datetime DESC) as rn
            FROM obs
            INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.voided = 0
            INNER JOIN encounter_type et ON et.encounter_type_id = e.encounter_type AND et.name = 'DIAGNOSIS'
            WHERE obs.voided = 0 AND obs.concept_id = 6542 AND obs.person_id IN (?)
          ) o
          WHERE o.rn = 1
          GROUP BY o.value_coded
        SQL
        
        results = ActiveRecord::Base.connection.select_all(
          ActiveRecord::Base.sanitize_sql([sql, @patient_ids])
        )
        
        type1 = 0
        type2 = 0
        hyper = 0
        other = 0
        
        results.each do |row|
          val = row['value_coded'].to_i
          cnt = row['cnt'].to_i
          if val == 6409
            type1 += cnt
          elsif val == 6410
            type2 += cnt
          elsif val == 8809 || val == 903
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

      # Quarterly breakdown by diagnosis for base patient cohort
      def diagnosis_quarterly_breakdown
        return default_quarterly_structure if @patient_ids.empty?
        
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          # Initialize sets to track unique patients per diagnosis
          type_one_patients = Set.new
          type_two_patients = Set.new
          hypertension_patients = Set.new
          
          # Get all diagnosis observations for base patient cohort
          diagnosis_observations = Observation.joins(encounter: :type)
                                              .where(person_id: @patient_ids)
                                              .where(encounter_type: { name: 'DIAGNOSIS' })
                                              .where('obs.obs_datetime BETWEEN ? AND ?', 
                                                     start_date.beginning_of_day, 
                                                     end_date.end_of_day)
                                              .where(concept_id: 6542) # Primary diagnosis concept
                                              .select('obs.person_id, obs.value_coded, obs.obs_datetime')
          
          # Group by patient and get their diagnosis in this quarter
          diagnosis_observations.group_by(&:person_id).each do |patient_id, observations|
            # Get the last diagnosis for this patient in this quarter (based on obs_datetime)
            last_diagnosis = observations.max_by(&:obs_datetime)
            
            case last_diagnosis.value_coded
            when 6409
              type_one_patients.add(patient_id)
            when 6410
              type_two_patients.add(patient_id)
            when 8809, 903
              hypertension_patients.add(patient_id)
            end
          end

          quarters[quarter_label] = {
            type_one: type_one_patients.size,
            type_two: type_two_patients.size,
            hypertension: hypertension_patients.size
          }
          
          end_date = start_date - 1.day
        end
        
        # Reverse to get chronological order and format for frontend
        reversed_quarters = quarters.to_a.reverse.to_h
        
        {
          categories: reversed_quarters.keys,
          type_one: reversed_quarters.values.map { |q| q[:type_one] },
          type_two: reversed_quarters.values.map { |q| q[:type_two] },
          hypertension: reversed_quarters.values.map { |q| q[:hypertension] }
        }
      end

      # Quarterly breakdown by gender for base patient cohort
      def gender_quarterly_breakdown
        return default_quarterly_structure if @patient_ids.empty?
        
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          # Get patients from base cohort who had ANY observation in this quarter
          # Using obs_datetime to match the diagnosis logic
          patients_in_quarter = Observation.where(person_id: @patient_ids)
                                          .where('obs.voided = 0')
                                          .where('obs.obs_datetime BETWEEN ? AND ?', 
                                                 start_date.beginning_of_day, 
                                                 end_date.end_of_day)
                                          .distinct
                                          .pluck(:person_id)

          quarters[quarter_label] = {
            male: Person.where(person_id: patients_in_quarter, gender: 'M').count,
            female: Person.where(person_id: patients_in_quarter, gender: 'F').count
          }
          
          end_date = start_date - 1.day
        end
        
        # Reverse to get chronological order and format for frontend
        reversed_quarters = quarters.to_a.reverse.to_h
        
        {
          categories: reversed_quarters.keys,
          male: reversed_quarters.values.map { |q| q[:male] },
          female: reversed_quarters.values.map { |q| q[:female] }
        }
      end

      def default_quarterly_structure
        {
          categories: [],
          male: [],
          female: [],
          type_one: [],
          type_two: [],
          hypertension: []
        }
      end

      def format_quarter_label(date)
        quarter_number = ((date.month - 1) / 3) + 1
        "Q#{quarter_number} #{date.year}"
      end
    end
  end
end