class Api::V1::ImmunizationReportController < ApplicationController
  before_action :report_params , only: [:stats, :vaccines_administered]

  def stats
    start_date = report_params[:start_date].to_date
    end_date = report_params[:end_date].to_date
    location_id = User.current.location_id

    dashboard_stats = fetch_or_build_dashboard_stats(start_date, end_date, location_id)
    dashboard_stats = refresh_due_counts!(dashboard_stats, location_id)

    DashboardStatsJob.perform_later(location_id, start_date.to_s, end_date.to_s)

    render json: dashboard_stats
  end

  def vaccine_names
    drugs = ConceptSet.joins(concept: %i[concept_names drugs])
                      .where(concept_set: ConceptName.where(name: 'Immunizations').pluck(:concept_id))
                      .group('concept.concept_id, drug.name, drug.drug_id')
                      .select('concept.concept_id, drug.name as name, drug.drug_id drug_id')

    vacine_drug_names = drugs.flat_map do |immunization_drug|
      vaccines = []
      ImmunizationService::VaccineScheduleService.vaccine_attribute(immunization_drug.concept_id, 'Immunization milestones').each_with_index do |milestone, i|
        vaccines << {
          name: ImmunizationService::VaccineScheduleService.vaccine_display_name(immunization_drug.name, i),
          drug_id: immunization_drug.drug_id,
        }
      end
      vaccines
    end
    
    render json: vacine_drug_names
  end

  def under_five_immunizations_drugs
    render json: ConceptName.joins("INNER JOIN concept_set s ON s.concept_id = concept_name.concept_id")
                            .joins("INNER JOIN drug ON drug.concept_id = concept_name.concept_id")
                            .where("s.concept_set = ? AND concept_name.name LIKE ? AND drug.retired = 0", 11894, "%#{params[:name]}%")
                            .group('concept_name.concept_id', 'drug.drug_id')
                            .select('concept_name.concept_id, concept_name.concept_name_id, drug.name, drug.drug_id')
  end

  def vaccines_administered
    start_date = report_params[:start_date]
    end_date = report_params[:end_date]

    # Get the current location id
    location_id = User.current.location_id

    vaccines_administered_service = ImmunizationService::Reports::General::VaccinesAdministered.new(start_date:,
                                                                                                    end_date:,
                                                                                                    location_id:)
    data = vaccines_administered_service.data

    render json: data
  end

  def aefi_report
    start_date = report_params[:start_date]
    end_date = report_params[:end_date]

    # Get the current location id
    location_id = User.current.location_id

    aefi_service = ImmunizationService::Reports::General::AefiReport.new(start_date:,
                                                                          end_date:,
                                                                          location_id:)
    data = aefi_service.data

    render json: data
  end

  def months_picker
    render json: months_generator
  end

  def weeks_picker
    render json: weeks_generator
  end

  def months_generator
    months = {}
    count = 0
    curr_date = Date.today
    
    while count < 13
      if count == 0
        months[curr_date.strftime('%Y/%m')] = [
          curr_date.strftime('%B-%Y'),
          "#{curr_date.beginning_of_month} to #{curr_date}"
        ]
      else
        months[curr_date.strftime('%Y/%m')] = [
          curr_date.strftime('%B-%Y'),
          "#{curr_date.beginning_of_month} to #{curr_date.end_of_month}"
        ]
      end
      
      curr_date -= 1.month
      count += 1
    end
    
    months.to_a
  end

  def weeks_generator
    weeks = {}
      first_day = (Date.today - 11.months).at_beginning_of_month
      add_initial_week(weeks, first_day)

      first_monday = first_day.next_week(:monday)

      while first_monday <= Date.today
        add_week(weeks, first_monday)
        first_monday += 7
      end

      this_wk = "#{Date.today.year}W#{Date.today.cweek}"
      weeks.reject { |key, _| key == this_wk }.to_a
  end

    # Adds the initial week to the weeks hash.
    # @param weeks [Hash] The hash to add the week to
    # @param first_day [Date] The first day of the initial week
  def add_initial_week(weeks, first_day)
    wk_of_first_day = first_day.cweek
      return unless wk_of_first_day > 1

      wk = "#{first_day.prev_year.year}W#{wk_of_first_day}"
      dates = "#{first_day - first_day.wday + 1} to #{first_day - first_day.wday + 1 + 6}"
      weeks[wk] = dates
  end

    # Adds a week to the weeks hash.
    # @param weeks [Hash] The hash to add the week to
    # @param first_monday [Date] The first Monday of the week
  def add_week(weeks, first_monday)
    wk = "#{first_monday.year}W#{first_monday.cweek}"
      dates = "#{first_monday} to #{first_monday + 6}"
      weeks[wk] = dates
  end

  private

  def report_params
    params.require(%i[start_date end_date])
    params.permit(%i[start_date end_date])
  end

  def fetch_or_build_dashboard_stats(start_date, end_date, location_id)
    fresh_stats = ImmunizationService::Reports::Stats::ImmunizationDashboard.new(
      start_date: start_date.to_s,
      end_date: end_date.to_s,
      location_id:
    ).data

    normalized = normalize_dashboard_stats_hash(fresh_stats)
    persist_cache('dashboard_stats', location_id, normalized)
    normalized
  rescue StandardError => e
    Rails.logger.error("Failed to build immunization dashboard stats for location #{location_id}: #{e.class}: #{e.message}")

    cached_stats = ImmunizationCacheDatum.where(name: 'dashboard_stats', location_id:).pick(:value)
    return normalize_dashboard_stats_hash(cached_stats) if cached_stats.present?

    default_dashboard_stats
  end

  def refresh_due_counts!(dashboard_stats, location_id)
    missed_visits = ImmunizationService::FollowUp.new.fetch_missed_immunizations(location_id)

    refreshed_stats = normalize_dashboard_stats_hash(dashboard_stats).merge(
      'under_five_overdue' => missed_visits[:under_five_count].to_i,
      'over_five_overdue' => missed_visits[:over_five_count].to_i,
      'due_today_count' => missed_visits[:due_today_count].to_i,
      'due_this_week_count' => missed_visits[:due_this_week_count].to_i,
      'due_this_month_count' => missed_visits[:due_this_month_count].to_i
    )

    persist_cache('dashboard_stats', location_id, refreshed_stats)
    persist_cache('missed_immunizations', location_id, missed_visits)

    refreshed_stats
  rescue StandardError => e
    Rails.logger.error("Failed to refresh due counts for location #{location_id}: #{e.class}: #{e.message}")
    normalize_dashboard_stats_hash(dashboard_stats)
  end

  def persist_cache(name, location_id, value)
    cache = ImmunizationCacheDatum.find_or_initialize_by(name:, location_id:)
    cache.value = value
    cache.save!
  end

  def normalize_dashboard_stats_hash(value)
    merged = default_dashboard_stats.merge((value || {}).to_h.deep_stringify_keys)
    merged.slice(*default_dashboard_stats.keys, 'total_male_registered', 'total_client_registered',
                 'total_female_registered', 'vaccination_counts_by_month')
  rescue StandardError
    default_dashboard_stats
  end

  def default_dashboard_stats
    {
      'total_vaccinated_this_year' => 0,
      'total_female_vaccinated_this_year' => 0,
      'total_male_vaccinated_this_year' => 0,
      'due_today_count' => 0,
      'due_this_week_count' => 0,
      'due_this_month_count' => 0,
      'under_five_overdue' => 0,
      'over_five_overdue' => 0
    }
  end
end
