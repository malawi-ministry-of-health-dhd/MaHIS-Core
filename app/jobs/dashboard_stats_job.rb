class DashboardStatsJob < ApplicationJob
  queue_as :default

  def perform(location_id, start_date = 1.year.ago.to_date.to_s, end_date = Date.today.to_s)
    dashboard_stats = ImmunizationCacheDatum.where(name: 'dashboard_stats',
                                                   location_id: location_id).pick(:value)

    if dashboard_stats.blank?
      ImmunizationReportJob.perform_now(start_date, end_date, location_id)
      dashboard_stats = ImmunizationCacheDatum.where(name: 'dashboard_stats',
                                                     location_id: location_id).pick(:value)
    end

    ActionCable.server.broadcast("immunization_report_channel_#{location_id}", dashboard_stats || default_dashboard_stats)
  rescue StandardError => e
    Rails.logger.error("DashboardStatsJob failed for location #{location_id}: #{e.class}: #{e.message}")
    ActionCable.server.broadcast("immunization_report_channel_#{location_id}", default_dashboard_stats)
  end

  private

  def default_dashboard_stats
    {
      total_vaccinated_this_year: 0,
      total_female_vaccinated_this_year: 0,
      total_male_vaccinated_this_year: 0,
      due_today_count: 0,
      due_this_week_count: 0,
      due_this_month_count: 0,
      under_five_overdue: 0,
      over_five_overdue: 0
    }
  end
end
