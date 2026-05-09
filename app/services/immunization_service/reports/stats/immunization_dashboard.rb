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
            months = []
            vaccinations = []
  
            12.times do |i|
              start_date = current_date.beginning_of_month - i.months
              end_date = current_date.end_of_month - i.months
  
              month_name = start_date.strftime('%b') # Short month name
              count = @immunizations.where(orders: { start_date: start_date.beginning_of_day..end_date.end_of_day }).count(:patient_id)
  
              months << month_name
              vaccinations << count
            end
  
            { months: months.reverse, vaccinations: vaccinations.reverse }
          end
  
        end
      end
    end
end
  
