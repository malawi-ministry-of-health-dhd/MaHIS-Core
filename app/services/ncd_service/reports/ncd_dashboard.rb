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
            categories: gender_quarterly_data.keys,
            femaleSeries: gender_quarterly_data.values.map { |q| q[:female] || 0 },
            maleSeries: gender_quarterly_data.values.map { |q| q[:male] || 0 }
          },
          diagnosis_data: {
            categories: diagnosis_quarterly_data.keys,
            typeOneSeries: diagnosis_quarterly_data.values.map { |q| q[:type_one] || 0 },
            typeTwoSeries: diagnosis_quarterly_data.values.map { |q| q[:type_two] || 0 },
            hypertentionSeries: diagnosis_quarterly_data.values.map { |q| q[:hypertention] || 0 }
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
        return {} if @patient_ids.empty?
        
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          # Get diagnosis observations for base patient cohort in this quarter
          base_query = Observation.joins(encounter: :type)
                                  .where(person_id: @patient_ids)
                                  .where(encounter_type: { name: 'DIAGNOSIS' })
                                  .where(location_id: @location_id)
                                  .where(
                                    encounter: { 
                                      encounter_datetime: start_date.beginning_of_day..end_date.end_of_day 
                                    }
                                  )

          quarters[quarter_label] = {
            type_one: base_query.where(obs: { value_coded: 6409 }).distinct.count(:person_id),
            type_two: base_query.where(obs: { value_coded: 6410 }).distinct.count(:person_id),
            hypertention: base_query.where(obs: { value_coded: [8809, 903] }).distinct.count(:person_id),
            date_range: {
              start: start_date.strftime('%Y-%m-%d'),
              end: end_date.strftime('%Y-%m-%d')
            }
          }
          
          end_date = start_date - 1.day
        end
        
        quarters.to_a.reverse.to_h
      end

      # Quarterly breakdown by gender for base patient cohort
      def gender_quarterly_breakdown
        return {} if @patient_ids.empty?
        
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          # Get patients from base cohort who had encounters in this quarter
          patients_in_quarter = Encounter.where(patient_id: @patient_ids)
                                        .where(program_id: 32)
                                        .where(location_id: @location_id)
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
        
        quarters.to_a.reverse.to_h
      end

      def format_quarter_label(date)
        quarter_number = ((date.month - 1) / 3) + 1
        "Q#{quarter_number} #{date.year}"
      end
    end
  end
end