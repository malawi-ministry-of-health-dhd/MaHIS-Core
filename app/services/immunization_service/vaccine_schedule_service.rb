module ImmunizationService
  module VaccineScheduleService
    # This module is used to get the vaccine schedule for a patient
    # TODO: This is more of hardcoding for the contants we need to move this to
    # the database as metadata so that they can be adjusted accordingly.
    ZERO_INDEXED_VACCINES = { bOPV: 'OPV' }.freeze
    ONE_INDEXED_VACCINES = {
      'DPT-HepB-Hib_vac': 'Penta', Rota_liq: 'Rota', PCV13: 'PCV',
      'MR vaccine': 'MR', 'HPV vaccine 4-valent': 'HPV', RTS: 'MV',
      'Albendazole (200mg tablet)': 'Albendazole (200mg tablet)',
      'Albendazole (400mg tablet)': 'Albendazole (400mg tablet)',
      'TD': 'TD', 'TD (0.5ml)': 'TD (0.5ml)', 'Vit A': 'Vit A'
    }.freeze
    VACCINE_NAME_MAP = { 'Pfizer-BioNTech COVID-19 vaccine': 'Pfizer COVID-19' }.freeze
    CUSTOM_WINDOW_PERIODS = { 'OPV 0': '14 weeks' }.freeze
    DRUGS_DISPENSED_CONCEPT = 'Drugs dispensed'.freeze
    BATCH_NUMBER_CONCEPT = 'Batch Number'.freeze
    FEMALE_ONLY_IMMUNIZATIONS_CONCEPT = 'Female only immunizations'.freeze
    FALLBACK_GENERIC_MILESTONES = [
      {
        age: 'At birth',
        antigens: [
          { key: :bcg, name: 'BCG', window: '24 months' },
          { key: :opv, name: 'OPV 0', window: '14 weeks' }
        ]
      },
      {
        age: '6 weeks',
        antigens: [
          { key: :opv, name: 'OPV 1', window: '24 months' },
          { key: :penta, name: 'Penta 1', window: '24 months' },
          { key: :rota, name: 'Rota 1', window: '24 months' },
          { key: :pcv, name: 'PCV 1', window: '24 months' }
        ]
      },
      {
        age: '10 weeks',
        antigens: [
          { key: :opv, name: 'OPV 2', window: '24 months' },
          { key: :penta, name: 'Penta 2', window: '24 months' },
          { key: :rota, name: 'Rota 2', window: '24 months' },
          { key: :pcv, name: 'PCV 2', window: '24 months' }
        ]
      },
      {
        age: '14 weeks',
        antigens: [
          { key: :opv, name: 'OPV 3', window: '24 months' },
          { key: :penta, name: 'Penta 3', window: '24 months' },
          { key: :pcv, name: 'PCV 3', window: '24 months' },
          { key: :ipv, name: 'IPV', window: '24 months' }
        ]
      },
      { age: '5 months', antigens: [{ key: :mv, name: 'MV 1', window: '36 Month' }] },
      {
        age: '6 months',
        antigens: [
          { key: :mv, name: 'MV 2', window: '36 Month' },
          { key: :vit_a, name: 'Vit A 1', window: '24 months' }
        ]
      },
      { age: '7 months', antigens: [{ key: :mv, name: 'MV 3', window: '36 Month' }] },
      {
        age: '9 months',
        antigens: [
          { key: :mr, name: 'MR 1', window: '24 months' },
          { key: :tcv, name: 'TCV', window: '24 months' }
        ]
      },
      {
        age: '1 year',
        antigens: [
          { key: :vit_a, name: 'Vit A 2', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 1', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 1', window: '5 years' }
        ]
      },
      { age: '15 months', antigens: [{ key: :mr, name: 'MR 2', window: '24 months' }] },
      {
        age: '18 months',
        antigens: [
          { key: :vit_a, name: 'Vit A 3', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 2', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 2', window: '5 years' }
        ]
      },
      { age: '22 months', antigens: [{ key: :mv, name: 'MV 4', window: '36 Month' }] },
      {
        age: '2 years',
        antigens: [
          { key: :vit_a, name: 'Vit A 4', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 3', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 3', window: '5 years' }
        ]
      },
      {
        age: '30 months',
        antigens: [
          { key: :vit_a, name: 'Vit A 5', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 4', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 4', window: '5 years' }
        ]
      },
      {
        age: '3 years',
        antigens: [
          { key: :vit_a, name: 'Vit A 6', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 5', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 5', window: '5 years' }
        ]
      },
      {
        age: '42 months',
        antigens: [
          { key: :vit_a, name: 'Vit A 7', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 6', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 6', window: '5 years' }
        ]
      },
      {
        age: '4 years',
        antigens: [
          { key: :vit_a, name: 'Vit A 8', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 7', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 7', window: '5 years' }
        ]
      },
      {
        age: '54 months',
        antigens: [
          { key: :vit_a, name: 'Vit A 9', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 8', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 8', window: '5 years' }
        ]
      },
      {
        age: '5 years',
        antigens: [
          { key: :vit_a, name: 'Vit A 10', window: '24 months' },
          { key: :alb_200, name: 'Albendazole (200mg tablet) 9', window: '5 years' },
          { key: :alb_400, name: 'Albendazole (400mg tablet) 9', window: '5 years' }
        ]
      },
      {
        age: '9 years',
        antigens: [
          { key: :hpv, name: 'HPV 1', window: '14 Years', female_only: true }
        ]
      },
      {
        age: '114 months',
        antigens: [
          { key: :hpv, name: 'HPV 2', window: '14 Years', female_only: true }
        ]
      },
      {
        age: '15 years',
        antigens: [
          { key: :td, name: 'TD 1', window: '100 years' }
        ]
      },
      {
        age: '180.9 months',
        antigens: [
          { key: :td, name: 'TD 2', window: '100 years' }
        ]
      },
      {
        age: '186 months',
        antigens: [
          { key: :td, name: 'TD 3', window: '100 years' }
        ]
      },
      {
        age: '12 years above',
        antigens: [
          { key: :covid_pfizer, name: 'Pfizer COVID-19', window: '100 years' }
        ]
      },
      {
        age: '18 years above',
        antigens: [
          { key: :covid_astrazeneca, name: 'AstraZeneca Covid 19', window: '100 years' },
          { key: :covid_jj, name: 'Johnson & Johnson Covid 19', window: '100 years' }
        ]
      },
      {
        age: '20 years',
        antigens: [
          { key: :td, name: 'TD 4', window: '100 years' }
        ]
      }
    ].freeze


    def self.vaccine_schedule(patient)
      # Get Vaccine Schedule
      # begin
      # Immunization Drugs
      immunizations = immunization_drugs

      if patient.gender&.split&.first&.casecmp?('M')
        immunizations = filter_female_specific_immunizations(immunizations)
      end

      vaccine_metadata = vaccine_metadata_for(immunizations.map(&:concept_id))
  
      # For each of these get the window period and schedule
      immunization_with_window = immunizations.flat_map do |immunization_drug|
        concept_id = immunization_drug.concept_id
        metadata = vaccine_metadata[concept_id] || {}
        milestones = metadata[:milestones] || []
        default_window_period = metadata[:window_period]

        vaccines = []
        milestones.each_with_index do |milestone, i|
          drug_name = vaccine_display_name(immunization_drug.name, i)
          vaccines << {
            milestone_name: milestone[:name],
            sort_weight: milestone[:sort_weight],
            drug_id: immunization_drug.drug_id,
            drug_name:,
            window_period: CUSTOM_WINDOW_PERIODS[drug_name.to_sym] || default_window_period
          }
        end
        vaccines
      end

      if immunization_with_window.blank?
        immunization_with_window = fallback_immunization_with_window(immunizations, patient.gender)
      end

      vaccines_given = administered_vaccines(patient.person_id, immunization_with_window.pluck(:drug_id))
      grouped_immunizations = immunization_with_window.group_by { | immunizations | immunizations[:milestone_name] }
      sorted_grouped_immunizations = grouped_immunizations.sort_by { |milestone| milestone[1][0][:sort_weight]}.to_h
      vaccines = format_schedule(make_unique(sorted_grouped_immunizations), vaccines_given, patient.birthdate)
  
      { vaccine_schedule: vaccines }
    end
  
  
    def self.make_unique(data)
      unique_data = data.each_with_object({}) do |(concept_set_id, milestone), hash|
        milestone.each do |drug|
          hash[concept_set_id] ||= []  # Initialize empty array for milestone drugs if not present
          hash[concept_set_id] << drug unless hash[concept_set_id].any? { |d| d[:drug_name] == drug[:drug_name] }
        end
      end
  
      unique_data
    end

    def self.vaccine_display_name(vaccine, index)
      if ZERO_INDEXED_VACCINES.keys.include?(vaccine.to_sym)
        "#{ZERO_INDEXED_VACCINES[vaccine.to_sym]} #{index}"
      elsif ONE_INDEXED_VACCINES.keys.include?(vaccine.to_sym)
        "#{ONE_INDEXED_VACCINES[vaccine.to_sym]} #{index + 1}"
      else
        VACCINE_NAME_MAP[vaccine.to_sym] || vaccine
      end
    end
  
  
    def self.age_in_years(birthdate)
      today = Date.today
      age = today.year - birthdate.year
      age -= 1 if today.month < birthdate.month || (today.month == birthdate.month && today.day < birthdate.day)
      age
    end
  
    def self.immunization_drugs
      ConceptSet.joins(concept: %i[concept_names drugs])
                .where(concept_set: ConceptName.where(name: 'Immunizations').pluck(:concept_id))
                .group('concept.concept_id, drug.name, drug.drug_id')
                .select('concept.concept_id, drug.name as name, drug.drug_id drug_id')
    end
  
    def self.filter_female_specific_immunizations(immunizations)
      female_only_concept_ids = ConceptSet.where(
        concept_set: ConceptName.where(name: FEMALE_ONLY_IMMUNIZATIONS_CONCEPT).select(:concept_id)
      ).pluck(:concept_id)

      immunizations.reject { |immunization| female_only_concept_ids.include?(immunization.concept_id) }
    end
  
  
  
    def self.update_milestone_status(vaccine_schedule)
      visit_one = vaccine_schedule.find { |visit| visit[:visit] == 1 }
      if visit_one[:antigens].any? { |antigen| antigen[:status] != 'administered' }
        visit_one[:milestone_status] = 'current'
        visit_one[:antigens].each do |antigen|
          antigen[:can_administer] = true if antigen[:status] == 'pending'
        end
  
        vaccine_schedule.each do |visit|
          next if visit[:visit] == 1
  
          visit[:milestone_status] = 'upcoming'
          visit[:antigens].each do |antigen|
            antigen[:can_administer] = false
          end
        end
      elsif visit_one[:antigens].all? { |antigen| antigen[:status] == 'administered' }
        visit_one[:milestone_status] = 'passed'
        administered_date = Date.strptime(visit_one[:antigens].first[:date_administered], '%d/%b/%Y %H:%M:%S')
  
        vaccine_schedule.each_with_index do |visit, index|
          next if visit[:visit] <= 1
  
          next_age_days = parse_age_to_days(visit[:age])
          visit[:milestone_status] = 'upcoming'
  
          next unless administered_date + next_age_days <= Date.today
  
          visit[:milestone_status] = 'current'
          visit[:antigens].each do |antigen|
            antigen[:can_administer] = true
          end
          break
        end
      end
  
      vaccine_schedule
    end
  
    def self.parse_age_to_days(age)
      units = {
        'day' => 1,
        'week' => 7,
        'month' => 30,
        'year' => 365
      }
  
      amount, unit = age.split
      amount.to_i * units[unit.downcase.chomp('s')]
    end
  
    def self.vaccine_attribute(drug_concept_id, attribute_type)
      ConceptSet.joins(concept: :concept_names)
                .where(concept_set: ConceptName.where(name: attribute_type).pluck(:concept_id))
                .where(concept_id: ConceptSet.where(concept_set: drug_concept_id).pluck(:concept_id))
                .select('concept_name.name, concept_set.sort_weight')
                .order(:sort_weight)
    end

    def self.vaccine_metadata_for(drug_concept_ids)
      drug_concept_ids = Array(drug_concept_ids).compact.uniq
      return {} if drug_concept_ids.empty?

      member_concept_ids_by_drug = ConceptSet.where(concept_set: drug_concept_ids)
                                             .pluck(:concept_set, :concept_id)
                                             .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(set_id, concept_id), hash|
        hash[set_id] << concept_id
      end

      member_concept_ids = member_concept_ids_by_drug.values.flatten.uniq
      return {} if member_concept_ids.empty?

      milestone_details = attribute_details_for_members(member_concept_ids, 'Immunization milestones')
      window_period_details = attribute_details_for_members(member_concept_ids, 'Immunization window period')

      drug_concept_ids.each_with_object({}) do |drug_concept_id, metadata|
        member_ids = member_concept_ids_by_drug[drug_concept_id]

        milestones = member_ids.filter_map do |member_id|
          milestone = milestone_details[member_id]
          next unless milestone

          { name: milestone[:name], sort_weight: milestone[:sort_weight] }
        end.sort_by { |milestone| milestone[:sort_weight].to_i }

        default_window_period = member_ids.filter_map do |member_id|
          window_period_details[member_id]&.dig(:name)
        end.first

        metadata[drug_concept_id] = {
          milestones: milestones,
          window_period: default_window_period
        }
      end
    end

    def self.attribute_details_for_members(member_concept_ids, attribute_type)
      return {} if member_concept_ids.blank?

      attribute_concept_ids = ConceptName.where(name: attribute_type).pluck(:concept_id)
      return {} if attribute_concept_ids.empty?

      ConceptSet.joins(concept: :concept_names)
                .where(concept_set: attribute_concept_ids, concept_id: member_concept_ids)
                .order('concept_set.sort_weight ASC, concept_name.concept_name_id ASC')
                .pluck('concept_set.concept_id', 'concept_set.sort_weight', 'concept_name.name')
                .each_with_object({}) do |(concept_id, sort_weight, name), details|
        details[concept_id] ||= { sort_weight: sort_weight, name: name }
      end
    end
  
    def self.format_schedule(schedule, vaccines_given, client_dob)
      schedule.map.with_index(1) do |(milestone_name, antigens), index|
        {
          visit: index,
          milestone_status: milestone_status(milestone_name, client_dob),
          age: milestone_name,
          antigens: antigens.map do |drug|
            vaccine_given = vaccines_given.find { |vaccine| vaccine[:drug_name] == drug[:drug_name] }
            vaccines = {
              drug_id: drug[:drug_id],
              drug_name: drug[:drug_name],
              window_period: drug[:window_period],
              can_administer: can_administer_drug?(drug, client_dob, milestone_name),
              status: vaccine_given ? 'administered' : 'pending',
              date_administered: vaccine_given&.[](:obs_datetime)&.strftime('%d/%b/%Y %H:%M:%S'),
              administered_by: vaccine_given&.[](:administered_by),
              location_administered: vaccine_given&.[](:location_administered),
              vaccine_batch_number: vaccine_given&.[](:batch_number),
              encounter_id: vaccine_given&.[](:encounter_id),
              order_id: vaccine_given&.[](:order_id)
            }
            vaccines_given.delete(vaccine_given) if vaccine_given
            vaccines
          end
        }
      end
    end

    def self.administered_vaccines(patient_id, drugs)
      return [] if drugs.blank?

      drug_name_dispensed = ConceptName.where(name: DRUGS_DISPENSED_CONCEPT).pluck(:concept_id)
      batch_number_concept_ids = ConceptName.where(name: BATCH_NUMBER_CONCEPT).pluck(:concept_id)

      observations = Observation.joins(person: :names)
                                .joins(order: :drug_order)
                                .where(drug_order: { drug_inventory_id: drugs }, person_id: patient_id)
                                .where(order: { voided: 0 })
                                .select(:obs_datetime, :drug_inventory_id, :order_id, :location_id,
                                        :creator, :given_name, :family_name, :encounter_id)
                                .to_a

      return [] if observations.empty?

      order_ids = observations.map(&:order_id).compact.uniq
      encounter_ids = observations.map(&:encounter_id).compact.uniq
      location_ids = observations.map(&:location_id).compact.uniq

      batch_numbers_by_order = Observation.where(concept_id: batch_number_concept_ids, order_id: order_ids)
                                          .where.not(value_text: nil)
                                          .order(:obs_id)
                                          .pluck(:order_id, :value_text)
                                          .each_with_object({}) do |(order_id, value_text), map|
        map[order_id] ||= value_text
      end

      drug_name_by_encounter = Observation.where(
        person_id: patient_id,
        encounter_id: encounter_ids,
        concept_id: drug_name_dispensed
      ).where.not(value_text: nil)
       .order(:obs_id)
       .pluck(:encounter_id, :value_text)
       .each_with_object({}) do |(encounter_id, value_text), map|
        map[encounter_id] ||= value_text
      end

      locations_by_id = Location.where(location_id: location_ids).index_by(&:location_id)

      observations.map do |obs|
        {
          obs_datetime: obs.obs_datetime,
          drug_inventory_id: obs.drug_inventory_id,
          batch_number: batch_numbers_by_order[obs.order_id],
          encounter_id: obs.encounter_id,
          order_id: obs.order_id,
          drug_name: drug_name_by_encounter[obs.encounter_id],
          administered_by: {
            person_id: obs.creator,
            given_name: obs.given_name,
            family_name: obs.family_name
          },
          location_administered: locations_by_id[obs.location_id]
        }
      end
    end
  
    def self.get_batch_id(order_id)
      Observation.where(concept_id: ConceptName.where(name: 'Batch Number').pluck(:concept_id), order_id:).first&.value_text
    end
  
  
    def self.milestone_status(milestone, dob)
      today = Date.today
      if milestone.casecmp('At Birth').zero?
        if today == dob
          'current'
        elsif today > dob
          'passed'
        else
          'upcoming'
        end
      elsif milestone.include?('weeks') || milestone.include?('week')
        milestone_weeks = milestone.split.first.to_i
        age_in_weeks = (today - dob).to_i / 7
        return 'current' if milestone_weeks == age_in_weeks.to_i
  
        age_in_weeks > milestone_weeks ? 'passed' : 'upcoming'
      elsif milestone.include?('months') || milestone.include?('month')
        milestone_months = milestone.split.first.to_i
        age_in_months = (today.year * 12 + today.month) - (dob.year * 12 + dob.month)
        return 'current' if milestone_months == age_in_months
  
        age_in_months > milestone_months ? 'passed' : 'upcoming'
      elsif milestone.include?('years') || milestone.include?('year')
        milestone_years = milestone.split.first.to_i
        age_in_years = (today - dob).to_i / 365

        case milestone_years
        when 9
          return 'current' if age_in_years >= 9
  
          default_milstone_status(age_in_years, milestone_years)
        when 12
          return 'current' if age_in_years >= 12
  
          default_milstone_status(age_in_years, milestone_years)
        when 15
          return 'current' if age_in_years >= 15 
  
          default_milstone_status(age_in_years, milestone_years)
        when 18
          return 'current' if age_in_years >= 18
  
          default_milstone_status(age_in_years, milestone_years)
        else
          return 'current' if milestone_years == age_in_years
  
          age_in_years > milestone_years ? 'passed' : 'upcoming'
        end
      end
    end
  
    def self.default_milstone_status(age, milestone)
      age > milestone ? 'passed' : 'upcoming'
    end
  
    def self.can_administer_drug?(drug, dob, milestone)
      drug[:window_period] = '100 years' if drug[:window_period].blank?
  
      if milestone == 'At birth'
        milestone_days = 0
      else
        milestone_days = parse_age_to_days(milestone)
      end
      age = Date.today - dob
      # Handle atigens that are valid in a range of ages
      value, units = drug[:window_period].split
      case units.downcase
      when 'week', 'weeks'
        compare_age(age.to_f / 7, value, milestone_days.to_f / 7)
      when 'month', 'months'
        compare_age(age.to_f / 30, value, milestone_days.to_f / 30)
      when 'year', 'years'
        compare_age(age.to_f / 365, value, milestone_days.to_f / 365)
      end
    end
  
  
    def self.compare_age(age, window_period, milestone_days)
      if window_period.include?('-')
        start_age, end_age = window_period.split('-').map(&:to_i)
        (age >= start_age) && (age <= end_age) && (age >= milestone_days)
      else
        (age <= window_period.to_f) && (age >= milestone_days)
      end
    end

    def self.generic_vaccine_schedule
      immunizations = immunization_drugs
    
      # Create separate schedules for males and females
      female_specific_immunizations = filter_male_specific_immunizations(immunizations)
      male_specific_immunizations = filter_female_specific_immunizations(immunizations)
    
      female_schedule = build_generic_schedule(female_specific_immunizations)
      male_schedule = build_generic_schedule(male_specific_immunizations)
    
      { female_schedule:, male_schedule: }
    end
    
    # Helper method to build the generic vaccine schedule
    def self.build_generic_schedule(immunizations)
      # For each drug, retrieve milestones and build a generic vaccine schedule
      immunization_with_window = immunizations.flat_map do |immunization_drug|
        vaccines = []
        vaccine_attribute(immunization_drug.concept_id, 'Immunization milestones').each_with_index do |milestone, i|
          drug_name = vaccine_display_name(immunization_drug.name, i)
          vaccines << {
            milestone_name: milestone.name,
            sort_weight: milestone.sort_weight,
            drug_id: immunization_drug.drug_id,
            drug_name: drug_name,
            window_period: CUSTOM_WINDOW_PERIODS[drug_name.to_sym] || vaccine_attribute(immunization_drug.concept_id,
                                                                                        'Immunization window period')
                          .first&.name
          }
        end
        vaccines
      end
    
      # Group immunizations by milestone and sort them by milestone order
      grouped_immunizations = immunization_with_window.group_by { |immunizations| immunizations[:milestone_name] }
      sorted_grouped_immunizations = grouped_immunizations.sort_by { |milestone| milestone[1][0][:sort_weight] }.to_h
    
      # Format the generic vaccine schedule
      format_generic_schedule(make_unique(sorted_grouped_immunizations))
    end

    def self.format_generic_schedule(schedule)
      schedule.map.with_index(1) do |(milestone_name, antigens), index|
        {
          visit: index,
          milestone_status: nil, # No patient-specific milestone status
          age: milestone_name,
          antigens: antigens.map do |drug|
            {
              drug_id: drug[:drug_id],
              drug_name: drug[:drug_name],
              window_period: drug[:window_period],
              can_administer: nil, # No patient-specific administration capability
              status: nil,         # No patient-specific status
              date_administered: nil,
              administered_by: nil,
              location_administered: nil,
              vaccine_batch_number: nil,
              encounter_id: nil,
              order_id: nil
            }
          end
        }
      end
    end
    
    # New method to filter male-specific immunizations
    def self.filter_male_specific_immunizations(immunizations)
      immunizations.reject do |immunization|
        ConceptSet.where(concept_set: ConceptName
                  .where(name: 'Male only immunizations').pluck(:concept_id))
                  .pluck(:concept_id).include?(immunization.concept_id)
      end
    end
    
    def self.filter_female_specific_immunizations(immunizations)
      # Exclude female-specific immunizations
      immunizations.reject do |immunization|
        ConceptSet.where(concept_set: ConceptName
                  .where(name: 'Female only immunizations').pluck(:concept_id))
                  .pluck(:concept_id).include?(immunization.concept_id)
      end
    end

    def self.fallback_immunization_with_window(immunizations, gender)
      gender_code = gender.to_s.strip.upcase.first
      drug_ids = fallback_drug_ids(immunizations)

      FALLBACK_GENERIC_MILESTONES.each_with_index.flat_map do |milestone, index|
        milestone[:antigens].filter_map do |antigen|
          next if antigen[:female_only] && gender_code == 'M'

          drug_id = drug_ids[antigen[:key]]
          next unless drug_id

          {
            milestone_name: milestone[:age],
            sort_weight: index + 1,
            drug_id: drug_id,
            drug_name: antigen[:name],
            window_period: antigen[:window]
          }
        end
      end
    end

    def self.fallback_drug_ids(immunizations)
      immunizations.each_with_object({}) do |immunization, ids|
        name = immunization.name.to_s.downcase
        ids[:bcg] ||= immunization.drug_id if name.include?('bcg')
        ids[:opv] ||= immunization.drug_id if name.include?('opv') || name.include?('bopv')
        ids[:penta] ||= immunization.drug_id if name.include?('dpt-hepb-hib') || name.include?('penta')
        ids[:rota] ||= immunization.drug_id if name.include?('rota')
        ids[:pcv] ||= immunization.drug_id if name.include?('pcv')
        ids[:ipv] ||= immunization.drug_id if name == 'ipv' || name.include?(' ipv')
        ids[:mv] ||= immunization.drug_id if name.include?('rts') || name.include?('mv')
        ids[:mr] ||= immunization.drug_id if name.include?('mr vaccine') || name.start_with?('mr ')
        ids[:tcv] ||= immunization.drug_id if name.include?('tcv')
        ids[:vit_a] ||= immunization.drug_id if name.include?('vit a')
        ids[:alb_200] ||= immunization.drug_id if name.include?('albendazole (200mg')
        ids[:alb_400] ||= immunization.drug_id if name.include?('albendazole (400mg')
        ids[:hpv] ||= immunization.drug_id if name.include?('hpv')
        ids[:td] ||= immunization.drug_id if name == 'td' || name.include?('tetanus diphtheria') || name.include?('td (0.5ml)')
        ids[:covid_pfizer] ||= immunization.drug_id if name.include?('pfizer')
        ids[:covid_astrazeneca] ||= immunization.drug_id if name.include?('astrazeneca')
        ids[:covid_jj] ||= immunization.drug_id if name.include?('johnson')
      end
    end
    
   
  end
end
