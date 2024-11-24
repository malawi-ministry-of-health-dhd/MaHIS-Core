module NcdService
  module Reports
    class NcdDashboard
      def find_report(start_date:, end_date:, **_extra_kwargs)
        dashboard
      end

      def dashboard
        @current_date = Date.current
        @location_id = User.current.location_id
        @registrations = fetch_registrations
        @diagnosis = fetch_diagnosis
        data
      end

      def data
        gender_quarterly_data = gender_quarterly_breakdown
        diagnosis_quarterly_data = diagnosis_quarterly_breakdown
        {
          total_client_registered: total_client_registered || 0,
          total_male_registered: total_male_registered || 0,
          total_female_registered: total_female_registered || 0,
          total_complications: fetch_complications.count(:person_id),
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

      def fetch_registrations
        base_query
          .where(
            encounter_type: { name: 'REGISTRATION' }
          )
          .distinct
      end

      def fetch_diagnosis
        base_query
          .where(
            encounter_type: { name: 'DIAGNOSIS' }
          )
          .distinct
      end

      def fetch_complications
        base_query
          .where(
            encounter_type: { name: 'COMPLICATIONS' }
          )
          .distinct
      end

      def base_query
        Observation.joins(concept: :concept_names,
                        encounter: %i[program type], person: [])
                  .where(program: { program_id: 32 }, location_id: @location_id)
      end

      def total_client_registered
        @registrations.count(:person_id)
      end

      def total_male_registered
        @registrations.where(person: { gender: 'M' }).count(:person_id)
      end

      def total_female_registered
        @registrations.where(person: { gender: 'F' }).count(:person_id)
      end

      def diagnosis_quarterly_breakdown
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          base_registrations = @diagnosis.where(
            encounter: { encounter_datetime: start_date.beginning_of_day..end_date.end_of_day }
          )

          quarters[quarter_label] = {
            type_one: base_registrations.where(obs: { value_coded: 6409 }).count(:person_id) || 0,
            type_two: base_registrations.where(obs: { value_coded: 6410 }).count(:person_id) || 0,
            hypertention:base_registrations.where(obs: { value_coded: 8809 }).count(:person_id) || 0,
            date_range: {
              start: start_date.strftime('%Y-%m-%d'),
              end: end_date.strftime('%Y-%m-%d')
            }
          }
          end_date = start_date - 1.day
        end
        quarters.to_a.reverse.to_h
      end

      def gender_quarterly_breakdown
        quarters = {}
        end_date = @current_date
        
        4.times do |i|
          start_date = end_date.beginning_of_quarter
          quarter_label = format_quarter_label(start_date)
          
          base_registrations = @registrations.where(
            encounter: { encounter_datetime: start_date.beginning_of_day..end_date.end_of_day }
          )

          quarters[quarter_label] = {
            male: base_registrations.where(person: { gender: 'M' }).count(:person_id) || 0,
            female: base_registrations.where(person: { gender: 'F' }).count(:person_id) || 0
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