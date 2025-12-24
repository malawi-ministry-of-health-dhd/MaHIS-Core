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
        
        {
          total_client_registered: @patient_ids.count,
          total_male_registered: total_male_registered,
          total_female_registered: total_female_registered,
          total_complications: total_complications,
          total_defaulters: count_defaulters,
          total_pending_dispensations: count_pending_dispensations,
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

      # Base query: Get all NCD patients for current location
      def get_patients
        sql = <<-SQL
          SELECT DISTINCT e.patient_id
          FROM (
            SELECT patient_id, location_id,
                  ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY encounter_datetime DESC) as rn
            FROM encounter WHERE voided = 0
          ) e
          INNER JOIN patient_program pp 
            ON e.patient_id = pp.patient_id 
            AND pp.program_id = 32 
            AND pp.voided = 0
          WHERE e.rn = 1 AND e.location_id = ?
        SQL
        
        Encounter.connection.select_values(
          ActiveRecord::Base.sanitize_sql([sql, @location_id])
        )
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
                   .where(location_id: @location_id)
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

      # Pending dispensations for base patient cohort
      def count_pending_dispensations
        return 0 if @patient_ids.empty?
                
        DrugOrder.joins(order: :encounter)
                 .where('orders.patient_id IN (?)', @patient_ids)
                 .where('drug_order.quantity <= 0')
                 .distinct
                 .count('orders.patient_id')
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
                                              .where(location_id: @location_id)
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
          
          # Get patients from base cohort who had ANY encounter in this quarter
          # This matches the frontend logic which checks if patient.encounter_datetime falls in quarter
          patients_in_quarter = Encounter.where(patient_id: @patient_ids)
                                        .where(voided: 0)
                                        .where(
                                          encounter_datetime: start_date.beginning_of_day..end_date.end_of_day
                                        )
                                        .distinct
                                        .pluck(:patient_id)

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