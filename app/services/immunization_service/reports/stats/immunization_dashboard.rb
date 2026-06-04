module ImmunizationService
    module Reports
      module Stats
        class ImmunizationDashboard
          IMMUNIZATION_PROGRAM_NAME = 'IMMUNIZATION PROGRAM'.freeze
          REGISTRATION_ENCOUNTER = 'REGISTRATION'.freeze
          TREATMENT_ENCOUNTER = 'TREATMENT'.freeze
  
          def initialize(start_date:, end_date:, location_id:)
            @current_date = Date.current
            @start_date = Date.parse(start_date).beginning_of_day
            @end_date = Date.parse(end_date).end_of_day
            @location_id = location_id
            @program_id = Program.find_by(name: IMMUNIZATION_PROGRAM_NAME)&.program_id || 33
            @registration_encounter_type_id = EncounterType.find_by(name: REGISTRATION_ENCOUNTER)&.encounter_type_id
            @treatment_encounter_type_id = EncounterType.find_by(name: TREATMENT_ENCOUNTER)&.encounter_type_id
            @registrations = fetch_registrations
            @immunizations = fetch_immunizations
          end
  
          def data
            {
              total_client_registered:,
              total_male_registered:,
              total_female_registered:,
              total_vaccinated_this_year:,
              total_female_vaccinated_this_year:,
              total_male_vaccinated_this_year:,
              vaccination_counts_by_month:
            }
          end
  
          private
  
          def fetch_registrations
            return Encounter.none if @registration_encounter_type_id.blank?

            Encounter.joins(patient: :person)
                     .where(
                       program_id: @program_id,
                       encounter_type: @registration_encounter_type_id,
                       location_id: @location_id,
                       voided: 0,
                       encounter_datetime: @start_date..@end_date
                     )
                     .distinct
          end

          def fetch_immunizations
            return Order.none if @treatment_encounter_type_id.blank?

            Order.joins(:drug_order, encounter: :program)
                 .joins(patient: :person)
                 .where(
                   orders: { voided: 0, start_date: @start_date..@end_date },
                   encounter: {
                     encounter_type: @treatment_encounter_type_id,
                     location_id: @location_id,
                     voided: 0
                   },
                   program: { program_id: @program_id }
                 )
                 .distinct
          end
  
          def total_client_registered
            @registrations.count(:patient_id)
          end
  
          def total_male_registered
            @registrations.where(person: { gender: 'M' }).count(:patient_id)
          end
  
          def total_female_registered
            @registrations.where(person: { gender: 'F' }).count(:patient_id)
          end
  
          def total_vaccinated_this_year
            @immunizations.count(:patient_id)
          end
  
          def total_female_vaccinated_this_year
            @immunizations.where(person: { gender: 'F' }).count(:patient_id)
          end
  
          def total_male_vaccinated_this_year
            @immunizations.where(person: { gender: 'M' }).count(:patient_id)
          end
  
          def vaccination_counts_by_month
            current_date = @end_date.to_date

            # Build the 12-month window (oldest → newest) up-front so the result
            # is well-defined even for months with zero vaccinations.
            window_starts = (0..11).map { |i| (current_date.beginning_of_month - i.months) }.reverse
            window_start = window_starts.first.beginning_of_day
            window_end   = current_date.end_of_month.end_of_day

            # Single grouped query replaces what used to be 12 separate COUNT
            # queries (each ~150ms on production-sized data → ~1.8s wasted per
            # dashboard refresh). MySQL needs YEAR/MONTH grouping because
            # `start_date` is a DATETIME with day-level resolution.
            grouped = @immunizations
                        .where(orders: { start_date: window_start..window_end })
                        .group(Arel.sql('YEAR(orders.start_date)'), Arel.sql('MONTH(orders.start_date)'))
                        .distinct
                        .count(:patient_id)

            # Key the result by [year, month] for O(1) lookup per bucket.
            by_bucket = grouped.each_with_object({}) do |((year, month), count), acc|
              acc[[year.to_i, month.to_i]] = count
            end

            months       = window_starts.map { |d| d.strftime('%b') }
            vaccinations = window_starts.map { |d| by_bucket[[d.year, d.month]] || 0 }

            { months: months, vaccinations: vaccinations }
          end
  
        end
      end
    end
end
  
